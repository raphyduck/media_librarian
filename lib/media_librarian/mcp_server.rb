# frozen_string_literal: true

require 'json'

require_relative 'version'

module MediaLibrarian
  # Model Context Protocol (JSON-RPC 2.0) front for the daemon control API.
  # Transport-agnostic: the daemon's /mcp endpoint (Streamable HTTP) and
  # scripts/mcp_stdio_bridge.rb both feed it parsed messages. Every tool is a
  # thin mapping onto an existing control route, reached through the `api`
  # callable (method, path, query:, body:) -> [status, parsed_body], so the MCP
  # surface can never drift from what the REST API and web UI do.
  class McpServer
    PROTOCOL_VERSIONS = %w[2025-11-25 2025-06-18 2025-03-26 2024-11-05].freeze
    SERVER_NAME = 'media_librarian'
    DEFAULT_LOG_LINES = 200
    MAX_LOG_LINES = 2_000
    DEFAULT_OUTPUT_LINES = 200
    FORBIDDEN_API_PATHS = %w[/mcp /ws /session].freeze
    CONFIRMED_API_PATHS = %w[/stop /update-stop].freeze

    PARSE_ERROR = -32_700
    INVALID_REQUEST = -32_600
    METHOD_NOT_FOUND = -32_601
    INVALID_PARAMS = -32_602
    INTERNAL_ERROR = -32_603

    INSTRUCTIONS = <<~TEXT
      Pilotage du démon media_librarian (collection vidéo et musique : calendrier des sorties,
      liste d'intérêts, recherche et file de torrents, traitement des fichiers).
      Pour voir où en est le serveur : `etat` (tâches en cours, en file, ressources) puis `journaux`.
      Les commandes longues (`lancer_commande`, `calendrier_rafraichir`) rendent un identifiant de tâche :
      suivre avec `tache`. Pour ajouter des films du calendrier à la liste d'intérêts : `calendrier`
      (ou `calendrier_chercher`) puis `liste_interets_ajouter` avec leurs imdb_id.
      `arreter` et `mettre_a_jour` coupent le démon : ne les appeler qu'avec l'accord explicite de
      l'utilisateur. Tout ce qu'aucun outil dédié ne couvre passe par `appeler_api`.
    TEXT

    class ToolError < StandardError; end

    class RpcError < StandardError
      attr_reader :code

      def initialize(code, message)
        super(message)
        @code = code
      end
    end

    Tool = Struct.new(:name, :title, :description, :input_schema, :annotations, :handler, keyword_init: true) do
      def to_h
        { 'name' => name, 'title' => title, 'description' => description,
          'inputSchema' => input_schema, 'annotations' => annotations }.compact
      end
    end

    attr_reader :tools

    def initialize(api:, version: MediaLibrarian::VERSION)
      @api = api
      @version = version.to_s
      @tools = build_tools.each_with_object({}) { |tool, memo| memo[tool.name] = tool }
    end

    # Handles one decoded JSON-RPC payload (a message or a batch). Returns the
    # response object(s) to serialize, or nil when nothing must be answered
    # (notifications, or a batch made only of notifications).
    def handle(payload)
      if payload.is_a?(Array)
        return error_message(nil, INVALID_REQUEST, 'Empty batch') if payload.empty?

        responses = payload.filter_map { |message| handle_message(message) }
        return responses.empty? ? nil : responses
      end

      handle_message(payload)
    end

    def handle_json(raw)
      payload = JSON.parse(raw.to_s)
    rescue JSON::ParserError => e
      error_message(nil, PARSE_ERROR, "Parse error: #{e.message}")
    else
      handle(payload)
    end

    private

    attr_reader :api

    def handle_message(message)
      unless message.is_a?(Hash) && message['jsonrpc'] == '2.0' && message['method'].is_a?(String)
        return nil if message.is_a?(Hash) && !message.key?('id') && message.key?('result')

        return error_message(message.is_a?(Hash) ? message['id'] : nil, INVALID_REQUEST, 'Invalid request')
      end

      id = message['id']
      notification = !message.key?('id')
      result = dispatch(message['method'], message['params'] || {})
      notification ? nil : { 'jsonrpc' => '2.0', 'id' => id, 'result' => result }
    rescue RpcError => e
      notification ? nil : error_message(id, e.code, e.message)
    rescue StandardError => e
      notification ? nil : error_message(id, INTERNAL_ERROR, e.message)
    end

    def dispatch(method, params)
      case method
      when 'initialize' then initialize_result(params)
      when 'ping' then {}
      when 'tools/list' then { 'tools' => tools.values.map(&:to_h) }
      when 'tools/call' then call_tool(params)
      when 'resources/list' then { 'resources' => [] }
      when 'resources/templates/list' then { 'resourceTemplates' => [] }
      when 'prompts/list' then { 'prompts' => [] }
      when %r{\Anotifications/} then {}
      else
        raise RpcError.new(METHOD_NOT_FOUND, "Method not found: #{method}")
      end
    end

    def initialize_result(params)
      requested = params.is_a?(Hash) ? params['protocolVersion'].to_s : ''
      version = PROTOCOL_VERSIONS.include?(requested) ? requested : PROTOCOL_VERSIONS.first
      {
        'protocolVersion' => version,
        'capabilities' => { 'tools' => { 'listChanged' => false } },
        'serverInfo' => { 'name' => SERVER_NAME, 'title' => 'Media Librarian', 'version' => @version },
        'instructions' => INSTRUCTIONS
      }
    end

    def call_tool(params)
      raise RpcError.new(INVALID_PARAMS, 'Invalid params') unless params.is_a?(Hash)

      tool = tools[params['name'].to_s]
      raise RpcError.new(INVALID_PARAMS, "Unknown tool: #{params['name']}") unless tool

      arguments = params['arguments'] || {}
      raise RpcError.new(INVALID_PARAMS, 'Tool arguments must be an object') unless arguments.is_a?(Hash)

      tool_result(tool.handler.call(arguments))
    rescue ToolError => e
      tool_result({ 'error' => e.message }, error: true)
    end

    def tool_result(value, error: false)
      structured = value.is_a?(Hash) ? value : { 'result' => value }
      {
        'content' => [{ 'type' => 'text', 'text' => JSON.pretty_generate(structured) }],
        'structuredContent' => structured,
        'isError' => error
      }
    end

    def error_message(id, code, message)
      { 'jsonrpc' => '2.0', 'id' => id, 'error' => { 'code' => code, 'message' => message } }
    end

    # Calls a control route and raises ToolError on a non-2xx answer, so the
    # model sees the route's own error message (e.g. restart_in_progress).
    def request(method, path, query: {}, body: nil)
      status, response = api.call(method, path, query: stringify_query(query), body: body)
      status = status.to_i
      unless status.between?(200, 299)
        message = response.is_a?(Hash) && response['error'] ? response['error'] : "HTTP #{status}"
        raise ToolError, "#{method} #{path} : #{message} (HTTP #{status})"
      end

      response.nil? ? { 'status' => status } : response
    end

    def stringify_query(query)
      (query || {}).each_with_object({}) do |(key, value), memo|
        next if value.nil? || value.to_s.empty?

        memo[key.to_s] = value.is_a?(Array) ? value.join(',') : value.to_s
      end
    end

    def require_argument(arguments, key)
      value = arguments[key]
      raise ToolError, "Argument manquant : #{key}" if value.nil? || value.to_s.strip.empty?

      value
    end

    def require_confirmation(arguments, action)
      return if arguments['confirmer'] == true

      raise ToolError, "#{action} : passer confirmer=true, uniquement avec l'accord explicite de l'utilisateur."
    end

    def bounded_integer(value, default:, max:)
      number = value.to_i
      number = default unless number.positive?
      [number, max].min
    end

    def last_lines(text, count, filter: nil)
      lines = text.to_s.split("\n")
      if filter && !filter.to_s.empty?
        needle = filter.to_s.downcase
        lines = lines.select { |line| line.downcase.include?(needle) }
      end
      lines.last(count).join("\n")
    end

    def command_parts(command)
      parts = case command
              when Array then command.map(&:to_s)
              else command.to_s.split(/[\s.]+/)
              end
      parts = parts.map(&:strip).reject(&:empty?)
      raise ToolError, 'Argument manquant : commande' if parts.empty?

      parts
    end

    def command_flags(arguments)
      return [] if arguments.nil?
      raise ToolError, 'arguments doit être un objet { nom: valeur }' unless arguments.is_a?(Hash)

      arguments.filter_map do |key, value|
        next if value.nil?

        rendered = case value
                   when true then '1'
                   when false then '0'
                   when Array then value.join(',')
                   when Hash then JSON.dump(value)
                   else value.to_s
                   end
        "--#{key.to_s.sub(/\A-+/, '')}=#{rendered}"
      end
    end

    def trim_job_output(job, lines)
      return job unless job.is_a?(Hash) && job['output']

      output = job['output']
      output = output.join("\n") if output.is_a?(Array)
      job.merge('output' => last_lines(output, lines))
    end

    def read_only
      { 'readOnlyHint' => true, 'openWorldHint' => false }
    end

    def mutating(destructive: false, idempotent: false)
      { 'readOnlyHint' => false, 'destructiveHint' => destructive, 'idempotentHint' => idempotent,
        'openWorldHint' => false }
    end

    def schema(properties = {}, required = [])
      base = { 'type' => 'object', 'properties' => properties, 'additionalProperties' => false }
      base['required'] = required unless required.empty?
      base
    end

    def tool(name, title, description, input_schema, annotations, &handler)
      Tool.new(name: name, title: title, description: description, input_schema: input_schema,
               annotations: annotations.merge('title' => title), handler: handler)
    end

    MEDIA_TYPE = { 'type' => 'string', 'enum' => %w[movies shows],
                   'description' => 'movies (films) ou shows (séries)' }.freeze
    CONFIRM = { 'type' => 'boolean', 'description' => "true, uniquement avec l'accord explicite de l'utilisateur" }.freeze

    def build_tools
      status_tools + command_tools + lifecycle_tools + calendar_tools + watchlist_tools +
        library_tools + generic_tools
    end

    def status_tools
      [
        tool('etat', 'État du serveur',
             "État du démon : tâches en cours, en file et terminées récemment (avec leur progression), " \
             'files par queue, date de démarrage, uptime, CPU et mémoire.',
             schema, read_only) { |_args| request('GET', '/status') },
        tool('journaux', 'Journaux',
             'Dernières lignes des journaux du démon (medialibrarian.log et medialibrarian_errors.log), ' \
             'avec filtre optionnel insensible à la casse.',
             schema(
               'fichier' => { 'type' => 'string', 'enum' => %w[tous general erreurs], 'default' => 'tous',
                              'description' => 'general = medialibrarian.log, erreurs = medialibrarian_errors.log' },
               'lignes' => { 'type' => 'integer', 'minimum' => 1, 'maximum' => MAX_LOG_LINES,
                             'default' => DEFAULT_LOG_LINES },
               'filtre' => { 'type' => 'string', 'description' => 'ne garder que les lignes contenant ce texte' }
             ),
             read_only) { |args| logs(args) }
      ]
    end

    def logs(args)
      count = bounded_integer(args['lignes'], default: DEFAULT_LOG_LINES, max: MAX_LOG_LINES)
      wanted = case args['fichier']
               when 'general' then ['medialibrarian.log']
               when 'erreurs' then ['medialibrarian_errors.log']
               end
      all = request('GET', '/logs')['logs'] || {}
      selected = wanted ? all.slice(*wanted) : all
      { 'logs' => selected.transform_values { |content| content && last_lines(content, count, filter: args['filtre']) } }
    end

    def command_tools
      [
        tool('commandes', 'Commandes disponibles',
             'Catalogue des commandes du démon (celles de la CLI `librarian`) avec leurs arguments, ' \
             'et les commandes préparées des modèles du planificateur.',
             schema, read_only) do |_args|
          { 'commands' => request('GET', '/commands')['commands'],
            'template_commands' => request('GET', '/template_commands')['commands'] }
        end,
        tool('lancer_commande', 'Lancer une commande',
             'Met en file une commande du démon, exactement comme la CLI (voir `commandes`). ' \
             'Ex. commande="library process_folder", arguments={"type":"shows","folder":"/chemin"} ; ' \
             'commande="torrent search", commande="library scan_file_system", commande="music organize" ' \
             'avec arguments={"apply":true}. Rend la tâche créée : suivre avec `tache`.',
             schema(
               {
                 'commande' => { 'description' => 'chemin de la commande : "library process_folder" ou ["library","process_folder"]',
                                 'oneOf' => [{ 'type' => 'string' }, { 'type' => 'array', 'items' => { 'type' => 'string' } }] },
                 'arguments' => { 'type' => 'object', 'description' => 'options --nom=valeur (true → 1, false → 0, liste → a,b)',
                                  'additionalProperties' => true },
                 'file' => { 'type' => 'string', 'description' => "queue d'exécution (défaut : celle de la commande)" },
                 'capturer_sortie' => { 'type' => 'boolean', 'default' => true,
                                        'description' => 'conserver la sortie de la tâche pour `tache`' }
               },
               ['commande']
             ),
             mutating) { |args| launch_command(args) },
        tool('tache', 'Suivre une tâche',
             "Statut, progression, résultat, erreur et fin de sortie d'une tâche du démon.",
             schema(
               { 'id' => { 'type' => 'string' },
                 'lignes_sortie' => { 'type' => 'integer', 'minimum' => 1, 'default' => DEFAULT_OUTPUT_LINES } },
               ['id']
             ),
             read_only) do |args|
          id = require_argument(args, 'id').to_s.strip
          job = request('GET', "/jobs/#{id}")
          trim_job_output(job, bounded_integer(args['lignes_sortie'], default: DEFAULT_OUTPUT_LINES, max: 5_000))
        end,
        tool('annuler_tache', 'Annuler une tâche', 'Annule une tâche en cours ou en file.',
             schema({ 'id' => { 'type' => 'string' } }, ['id']),
             mutating(destructive: true, idempotent: true)) do |args|
          request('DELETE', "/jobs/#{require_argument(args, 'id').to_s.strip}")
        end
      ]
    end

    def launch_command(args)
      command = command_parts(require_argument(args, 'commande')) + command_flags(args['arguments'])
      body = { 'command' => command, 'capture_output' => args.fetch('capturer_sortie', true) }
      body['queue'] = args['file'] if args['file'] && !args['file'].to_s.empty?
      response = request('POST', '/jobs', body: body)
      raise ToolError, 'Commande refusée par le démon (file pleine ou commande inconnue)' unless response['accepted']

      response
    end

    def lifecycle_tools
      [
        tool('redemarrer', 'Redémarrer le démon',
             'Redémarre le démon : attend la fin propre des tâches puis relance le processus depuis le disque. ' \
             "L'API ne répond plus pendant quelques secondes.",
             schema, mutating(idempotent: true)) { |_args| request('POST', '/restart') },
        tool('recharger', 'Recharger la configuration',
             'Recharge sans redémarrer : conf.yml (config), api.yml (api) ou le modèle du planificateur (planificateur).',
             schema({ 'cible' => { 'type' => 'string', 'enum' => %w[config api planificateur] } }, ['cible']),
             mutating(idempotent: true)) do |args|
          path = { 'config' => '/config/reload', 'api' => '/api-config/reload',
                   'planificateur' => '/scheduler/reload' }[args['cible']]
          raise ToolError, 'cible inconnue (config, api ou planificateur)' unless path

          request('POST', path)
        end,
        tool('arreter', 'Arrêter le démon',
             "Arrête le démon. L'API disparaît avec lui : seul le superviseur (systemd) peut le relancer. " \
             "Exige confirmer=true, avec l'accord explicite de l'utilisateur.",
             schema({ 'confirmer' => CONFIRM }, ['confirmer']),
             mutating(destructive: true)) do |args|
          require_confirmation(args, 'Arrêt du démon')
          request('POST', '/stop')
        end,
        tool('mettre_a_jour', 'Mettre à jour le code',
             'git pull du dépôt (update_root de api.yml) puis arrêt du démon pour que le superviseur le relance ' \
             "sur le nouveau code. Exige confirmer=true, avec l'accord explicite de l'utilisateur.",
             schema({ 'confirmer' => CONFIRM }, ['confirmer']),
             mutating(destructive: true)) do |args|
          require_confirmation(args, 'Mise à jour du démon')
          request('POST', '/update-stop')
        end
      ]
    end

    def calendar_tools
      [
        tool('calendrier', 'Calendrier des sorties',
             'Sorties à venir ou récentes suivies par le calendrier, filtrables. Chaque entrée porte imdb_id, ' \
             'titre, type, date, notes, et les drapeaux downloaded (déjà en collection) et in_interest_list (déjà dans la ' \
             "liste d'intérêts). Par défaut : les 7 jours à partir d'aujourd'hui.",
             schema(
               'type' => { 'type' => 'string', 'enum' => %w[movie show] },
               'titre' => { 'type' => 'string' },
               'genres' => { 'type' => 'array', 'items' => { 'type' => 'string' } },
               'note_imdb_min' => { 'type' => 'number' },
               'note_imdb_max' => { 'type' => 'number' },
               'votes_imdb_min' => { 'type' => 'integer' },
               'langue' => { 'type' => 'string' },
               'pays' => { 'type' => 'string' },
               'telecharge' => { 'type' => 'boolean' },
               'interet' => { 'type' => 'boolean' },
               'debut' => { 'type' => 'string', 'description' => 'date AAAA-MM-JJ' },
               'fin' => { 'type' => 'string', 'description' => 'date AAAA-MM-JJ' },
               'fenetre_jours' => { 'type' => 'integer', 'description' => 'largeur de la fenêtre sans dates explicites (défaut 7)' },
               'decalage' => { 'type' => 'integer', 'description' => 'décalage en fenêtres (-1 = la précédente)' },
               'tri' => { 'type' => 'string' },
               'page' => { 'type' => 'integer', 'minimum' => 1 },
               'par_page' => { 'type' => 'integer', 'minimum' => 1 }
             ),
             read_only) { |args| request('GET', '/calendar', query: calendar_query(args)) },
        tool('calendrier_chercher', 'Chercher un titre',
             'Cherche un film ou une série chez les fournisseurs (TMDB, Trakt, OMDB) et dans le calendrier local. ' \
             'Les résultats in_calendar=true peuvent aller directement dans la liste d\'intérêts ; les autres ' \
             'passent par `calendrier_importer`.',
             schema(
               {
                 'titre' => { 'type' => 'string' },
                 'annee' => { 'type' => 'integer' },
                 'type' => { 'type' => 'string', 'enum' => %w[movie show] },
                 'sources' => { 'type' => 'array', 'items' => { 'type' => 'string', 'enum' => %w[tmdb trakt omdb] } },
                 'limite' => { 'type' => 'integer', 'minimum' => 1, 'maximum' => 50 }
               },
               ['titre']
             ),
             read_only.merge('openWorldHint' => true)) do |args|
          request('GET', '/calendar/search',
                  query: { 'title' => require_argument(args, 'titre'), 'year' => args['annee'], 'type' => args['type'],
                           'sources' => args['sources'], 'limit' => args['limite'] })
        end,
        tool('calendrier_importer', 'Importer dans le calendrier',
             'Ajoute au calendrier une entrée rendue par `calendrier_chercher` (la passer telle quelle dans ' \
             "`entree`) et, si liste_interets=true, l'ajoute aussi à la liste d'intérêts.",
             schema(
               {
                 'entree' => { 'type' => 'object', 'additionalProperties' => true,
                               'description' => 'au minimum imdb_id, title et type (movie/show)' },
                 'liste_interets' => { 'type' => 'boolean', 'default' => true }
               },
               ['entree']
             ),
             mutating(idempotent: true)) do |args|
          entry = args['entree']
          raise ToolError, 'entree doit être un objet' unless entry.is_a?(Hash)

          request('POST', '/calendar/import',
                  body: entry.merge('watchlist' => args.fetch('liste_interets', true)))
        end,
        tool('calendrier_rafraichir', 'Rafraîchir le calendrier',
             'Lance le rafraîchissement du calendrier depuis les fournisseurs (tâche de fond, suivre avec `tache`).',
             schema(
               'jours' => { 'type' => 'integer', 'minimum' => 1 },
               'limite' => { 'type' => 'integer', 'minimum' => 1 },
               'sources' => { 'type' => 'array', 'items' => { 'type' => 'string' } }
             ),
             mutating) do |args|
          body = { 'days' => args['jours'], 'limit' => args['limite'], 'sources' => args['sources'] }.compact
          request('POST', '/calendar/refresh', body: body)
        end
      ]
    end

    def calendar_query(args)
      interest = args.key?('interet') ? (args['interet'] ? 'true' : 'false') : nil
      downloaded = args.key?('telecharge') ? (args['telecharge'] ? 'true' : 'false') : nil
      {
        'type' => args['type'], 'title' => args['titre'], 'genres' => args['genres'],
        'imdb_min' => args['note_imdb_min'], 'imdb_max' => args['note_imdb_max'],
        'imdb_votes_min' => args['votes_imdb_min'], 'language' => args['langue'], 'country' => args['pays'],
        'downloaded' => downloaded, 'interest' => interest,
        'start_date' => args['debut'], 'end_date' => args['fin'],
        'window' => args['fenetre_jours'], 'offset' => args['decalage'],
        'sort' => args['tri'], 'page' => args['page'], 'per_page' => args['par_page']
      }
    end

    def watchlist_tools
      [
        tool('liste_interets', "Liste d'intérêts",
             "Films et séries de la liste d'intérêts (watchlist), avec les torrents en attente qui leur " \
             'correspondent.',
             schema('type' => MEDIA_TYPE), read_only) do |args|
          request('GET', '/watchlist', query: { 'type' => args['type'] })
        end,
        tool('liste_interets_ajouter', "Ajouter à la liste d'intérêts",
             "Ajoute un ou plusieurs titres du calendrier à la liste d'intérêts par imdb_id (titre et type sont " \
             "repris du calendrier). Un titre absent du calendrier doit d'abord passer par `calendrier_importer`.",
             schema(
               {
                 'elements' => {
                   'type' => 'array', 'minItems' => 1,
                   'items' => {
                     'type' => 'object',
                     'properties' => { 'imdb_id' => { 'type' => 'string' }, 'titre' => { 'type' => 'string' },
                                       'type' => MEDIA_TYPE },
                     'required' => ['imdb_id']
                   }
                 }
               },
               ['elements']
             ),
             mutating(idempotent: true)) { |args| add_to_watchlist(args) },
        tool('liste_interets_retirer', "Retirer de la liste d'intérêts",
             "Retire un titre de la liste d'intérêts.",
             schema({ 'imdb_id' => { 'type' => 'string' }, 'type' => MEDIA_TYPE }, ['imdb_id']),
             mutating(destructive: true, idempotent: true)) do |args|
          request('DELETE', '/watchlist', body: { 'imdb_id' => require_argument(args, 'imdb_id'), 'type' => args['type'] }.compact)
        end
      ]
    end

    def add_to_watchlist(args)
      elements = args['elements']
      raise ToolError, 'elements doit être une liste non vide' unless elements.is_a?(Array) && !elements.empty?

      results = elements.map do |element|
        element = { 'imdb_id' => element } if element.is_a?(String)
        imdb_id = element.is_a?(Hash) ? element['imdb_id'].to_s.strip : ''
        next { 'imdb_id' => imdb_id, 'status' => 'error', 'error' => 'missing_imdb_id' } if imdb_id.empty?

        body = { 'imdb_id' => imdb_id, 'title' => element['titre'], 'type' => element['type'] }.compact
        begin
          request('POST', '/watchlist', body: body)
          { 'imdb_id' => imdb_id, 'status' => 'added' }
        rescue ToolError => e
          { 'imdb_id' => imdb_id, 'status' => 'error', 'error' => e.message }
        end
      end
      added = results.count { |result| result['status'] == 'added' }
      raise ToolError, JSON.dump(results) if added.zero?

      { 'added' => added, 'results' => results }
    end

    def library_tools
      [
        tool('collection', 'Collection locale',
             'Films et séries présents dans la collection locale, paginés.',
             schema(
               'type' => { 'type' => 'string', 'enum' => %w[all movie show unmatched] },
               'recherche' => { 'type' => 'string' },
               'tri' => { 'type' => 'string', 'enum' => %w[released_at year title] },
               'page' => { 'type' => 'integer', 'minimum' => 1 },
               'par_page' => { 'type' => 'integer', 'minimum' => 1 }
             ),
             read_only) do |args|
          request('GET', '/collection',
                  query: { 'type' => args['type'], 'search' => args['recherche'], 'sort' => args['tri'],
                           'page' => args['page'], 'per_page' => args['par_page'] })
        end,
        tool('torrents_en_attente', 'Torrents en attente',
             'Torrents trouvés en attente de validation manuelle (validation) et en attente de téléchargement (downloads).',
             schema, read_only) { |_args| request('GET', '/torrents/pending') },
        tool('torrent_valider', 'Valider un torrent',
             'Valide un torrent en attente de validation pour qu\'il parte au téléchargement.',
             schema({ 'identifiant' => { 'type' => 'string', 'description' => 'identifier ou name rendu par torrents_en_attente' } },
                    ['identifiant']),
             mutating(idempotent: true)) do |args|
          request('POST', '/torrents/validate', body: { 'identifier' => require_argument(args, 'identifiant') })
        end,
        tool('torrent_supprimer', 'Écarter un torrent',
             "Retire un torrent de la file d'attente (base de données seulement, aucun fichier n'est touché).",
             schema({ 'identifiant' => { 'type' => 'string' } }, ['identifiant']),
             mutating(destructive: true, idempotent: true)) do |args|
          request('POST', '/torrents/delete', body: { 'identifier' => require_argument(args, 'identifiant') })
        end,
        tool('configuration_lire', 'Lire la configuration',
             'Contenu de conf.yml (config), api.yml (api) ou du modèle du planificateur (planificateur). ' \
             'Les secrets sont masqués.',
             schema({ 'fichier' => { 'type' => 'string', 'enum' => %w[config api planificateur] } }, ['fichier']),
             read_only) do |args|
          path = { 'config' => '/config', 'api' => '/api-config', 'planificateur' => '/scheduler' }[args['fichier']]
          raise ToolError, 'fichier inconnu (config, api ou planificateur)' unless path

          request('GET', path)
        end
      ]
    end

    def generic_tools
      [
        tool('appeler_api', "Appeler l'API de contrôle",
             "Accès direct à n'importe quelle route de l'API REST du démon, pour ce qu'aucun outil dédié ne couvre. " \
             'Routes : /status, /jobs, /jobs/<id>, /commands, /template_commands, /logs, /restart, /stop, /update-stop, ' \
             '/calendar, /calendar/search, /calendar/import, /calendar/refresh, /collection, /watchlist, ' \
             '/watchlist/import-csv (csv_content, replace, async), /torrents/pending, /torrents/validate, /torrents/delete, ' \
             '/config, /config/reload, /api-config, /api-config/reload, /scheduler, /scheduler/reload, /templates, ' \
             '/templates/<fichier>.yml, /trackers, /trackers/<fichier>.yml, /trackers/info, /music/search (query, quality), ' \
             '/music/download, /music/import-csv, /music/organize. Écrire un fichier (PUT {"content": ...}), /stop et ' \
             "/update-stop exigent confirmer=true, avec l'accord explicite de l'utilisateur.",
             schema(
               {
                 'methode' => { 'type' => 'string', 'enum' => %w[GET POST PUT DELETE] },
                 'chemin' => { 'type' => 'string', 'description' => 'ex. /music/search' },
                 'parametres' => { 'type' => 'object', 'additionalProperties' => true, 'description' => 'paramètres de requête (GET)' },
                 'corps' => { 'type' => 'object', 'additionalProperties' => true, 'description' => 'corps JSON' },
                 'confirmer' => CONFIRM
               },
               %w[methode chemin]
             ),
             mutating(destructive: true).merge('openWorldHint' => true)) { |args| call_api(args) }
      ]
    end

    def call_api(args)
      method = require_argument(args, 'methode').to_s.upcase
      raise ToolError, 'methode : GET, POST, PUT ou DELETE' unless %w[GET POST PUT DELETE].include?(method)

      path = '/' + require_argument(args, 'chemin').to_s.strip.sub(%r{\A/+}, '')
      path = path.split('?', 2).first
      raise ToolError, 'chemin invalide' if path.include?('..')
      if FORBIDDEN_API_PATHS.any? { |forbidden| path == forbidden || path.start_with?("#{forbidden}/") }
        raise ToolError, "#{path} n'est pas accessible par appeler_api"
      end

      if method == 'PUT' || (method == 'POST' && CONFIRMED_API_PATHS.include?(path))
        require_confirmation(args, "#{method} #{path}")
      end

      body = args['corps']
      raise ToolError, 'corps doit être un objet' if body && !body.is_a?(Hash)

      params = args['parametres'] || {}
      raise ToolError, 'parametres doit être un objet' unless params.is_a?(Hash)

      request(method, path, query: params, body: body)
    end
  end
end
