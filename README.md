# media_librarian

WARNING: This is beta software. It might not work as intended.

What is it?
This program is made to answer my various needs for automation in the management of video media collections.

## Installation

1. **Clone the repository** and switch into it:

   ```bash
   git clone https://github.com/USERNAME/media_librarian.git
   cd media_librarian
   ```

2. **Install the system and Ruby dependencies.** The project provides a helper script that tries to detect your package manager and install the required tools (flac, lame, mediainfo, ffmpeg, mkvtoolnix, MakeMKV) before running Bundler:

   ```bash
   ./install.sh
   ```

   If you prefer installing things manually, make sure you install the packages listed above and then run Bundler yourself:

   ```bash
   gem install bundler:2.3.22
   bundle config set deployment 'true'
   bundle install --jobs 4 --retry 3
   ```

3. **Create your configuration directory** (the daemon looks under `~/.medialibrarian/`) and copy the provided examples as a starting point:

   ```bash
   mkdir -p ~/.medialibrarian
   cp config/conf.yml.example ~/.medialibrarian/conf.yml
   cp config/api.yml.example ~/.medialibrarian/api.yml
   ```

   Edit both files to match your environment (torrent client credentials, ffmpeg settings, API tokens, TLS options, etc.). Passwords should generally be stored as BCrypt hashes in `api.yml`.

## Usage

### CLI / daemon

* Run the daemon with your configuration file:

  ```bash
  bundle exec ruby librarian.rb daemon start --config ~/.medialibrarian/conf.yml
  ```

* Stop it when needed:

  ```bash
  bundle exec ruby librarian.rb daemon stop
  ```

* You can also execute a one-shot command without the daemon by pointing directly at the configuration file:

  ```bash
  bundle exec ruby librarian.rb --config ~/.medialibrarian/conf.yml
  ```

The daemon logs to `~/.medialibrarian/logs/` by default, and jobs are queued according to the values configured in `conf.yml`.

### Trakt integration

`TraktAgent` is now a thin shim that forwards dynamic API calls via `method_missing`. Legacy helpers for list management and automated watchlist/collection curation have been retired. Features such as the calendar rely on locally persisted watchlist entries instead of pulling Trakt lists directly.

### Calendar feed configuration

`CalendarFeedService` can hydrate the `calendar_entries` table from multiple sources. Each provider is toggled via the `calendar.providers` list in `~/.medialibrarian/conf.yml`, and the daemon scheduler uses the rest of the `calendar` keys to control refresh cadence and the window that gets persisted:

```yaml
calendar:
  refresh_every: 12 hours        # Scheduler interval (e.g. "6h", "1 day")
  refresh_on_start: true         # Prime the table on daemon boot when it's empty
  window_past_days: 30           # How far back from today to keep entries
  window_future_days: 45         # How far into the future to fetch releases
  refresh_limit: 200             # Maximum number of entries persisted per refresh
  providers: omdb|trakt|tmdb     # Pipe/comma/space separated list or array of sources to enable

tmdb:
  api_key: YOUR_TMDB_API_KEY

omdb:
  api_key: YOUR_OMDB_API_KEY

trakt:
  client_id: YOUR_TRAKT_CLIENT_ID
  client_secret: YOUR_TRAKT_CLIENT_SECRET
  access_token: OPTIONAL_OAUTH_TOKEN
```

`refresh_every` overrides the scheduler interval so the daemon automatically re-hydrates the calendar at the requested cadence. `window_past_days` and `window_future_days` define the rolling window of dates that will be fetched on each run (`refresh_days` remains a backward-compatible alias for the future window), while `refresh_limit` caps the number of entries persisted per refresh. `refresh_on_start` ensures the daemon performs an immediate refresh when the calendar table is empty (set it to `false` to disable that bootstrap). `providers` can be specified as a delimited string (`omdb|trakt|tmdb`, `omdb trakt`, etc.) or as a YAML array, and only the enabled fetchers are queried on each refresh.

The OMDb fetcher relies on an API key (`omdb.api_key`) and maps OMDb/IMDb metadata into the calendar feed. Run with `--debug=1` to surface OMDb enrichment logging when diagnosing missing metadata. Trakt access still requires an API application; `client_id`/`client_secret` identify the app and the calendar endpoints live under `https://api.trakt.tv/calendars/all/...`. Public calendars work with only the client id, but supplying an OAuth `access_token` allows the service to reuse authenticated calls if you later point it at user-specific scopes.

### Tracker logins that require a real browser

Some trackers now require interactive authentication flows that break automated form submissions. When that happens you can flag
the corresponding login metadata with `browser_login: true` (stored in `~/.medialibrarian/trackers/<tracker>.login.yml`). The
login command will launch a Selenium WebDriver instance, open the configured `login_url` in a real browser, and pause until you
confirm the login is complete (the prompt is skipped when running with `--no-prompt`). The captured browser cookies are injected
into the Mechanize agent and saved via the regular cookie cache so subsequent searches reuse the authenticated session.

Each tracker configuration (`~/.medialibrarian/trackers/<tracker>.yml`) can also expose a `url_template` to build manual search
links in the web interface. The template accepts `%title%`, `%year%` and `%imdbid%` placeholders (URL-encoded at render time)
and is returned by the `/trackers/info` endpoint for the dashboard dropdown.

The feature relies on the `selenium-webdriver` gem and an actual browser driver (`geckodriver`/Firefox by default, override with
`browser_driver` in the metadata). Make sure the matching browser and driver binary are installed and available on your `PATH`.

## Contrôle HTTP et interface web

Le démon expose un serveur HTTP léger (WEBrick) permettant de piloter les jobs, consulter les logs et éditer les fichiers de configuration YAML. Une interface web statique est disponible à l'adresse racine `/` et consomme les endpoints JSON (`/status`, `/logs`, `/config`, `/scheduler`).

### Lancement

1. Démarrer le démon (ex. `bundle exec ruby librarian.rb daemon start`).
2. Par défaut le serveur écoute sur `127.0.0.1:8888` (configurable via `~/.medialibrarian/api.yml`).
3. Ouvrir un navigateur sur `http://127.0.0.1:8888/` (ou `https://127.0.0.1:8888/` si TLS est activé) pour accéder au tableau de bord.

### Authentification et sessions

La consultation et la modification du démon HTTP nécessitent désormais une session authentifiée. Configurez un nom d'utilisateur et un mot de passe haché (BCrypt) dans `~/.medialibrarian/api.yml` avant le démarrage :

```yaml
bind_address: 127.0.0.1
listen_port: 8888
auth:
  username: admin
  password_hash: "$2a$12$REPLACE_WITH_BCRYPT_HASH"
```

Pour exposer l'interface via HTTPS, complétez le même fichier YAML avec les paramètres TLS :

```yaml
bind_address: 0.0.0.0
listen_port: 8443
auth:
  username: admin
  password_hash: "$2a$12$REPLACE_WITH_BCRYPT_HASH"
ssl_enabled: true
ssl_certificate_path: /chemin/vers/cert.pem
ssl_private_key_path: /chemin/vers/cle.pem
# Optionnel : chaîne de confiance et vérification côté client
ssl_ca_path: /chemin/vers/ca.pem
ssl_verify_mode: peer
ssl_client_verify_mode: none
```

Si aucune paire clé/certificat n'est fournie, le démon génère un certificat auto-signé éphémère : le navigateur et le client CLI devront alors explicitement faire confiance au certificat (accepter l'exception de sécurité en développement ou installer la CA). Le client CLI détecte automatiquement la configuration HTTPS (`ssl_enabled`) et ajuste la vérification selon `ssl_verify_mode`. Les valeurs acceptées pour `ssl_verify_mode` sont `none`, `peer`, `fail_if_no_peer_cert` / `force_peer` / `require`.

Le serveur d'administration continue d'autoriser les connexions sans certificat client (`ssl_client_verify_mode` = `none` par défaut). Pour activer l'authentification mutuelle TLS, fournissez une valeur explicite (`peer`, `require`, etc.) pour `ssl_client_verify_mode`; dans ce cas, WEBrick exigera un certificat client valide.

Depuis l'interface web, un formulaire de connexion envoie les identifiants à `POST /session` et un cookie sécurisé (`Secure`, `HttpOnly`) est retourné lorsque l'authentification réussit. La déconnexion s'effectue via `DELETE /session`.

Pour la rétrocompatibilité (clients CLI, automatisations, etc.), il reste possible de définir un jeton d'API qui autorise les requêtes munies de l'en-tête `X-Control-Token` (ou du paramètre `token`). Le jeton peut être fourni via les clés `api_token`/`control_token` du fichier `~/.medialibrarian/api.yml` ou, à défaut, les variables d'environnement `MEDIA_LIBRARIAN_API_TOKEN` / `MEDIA_LIBRARIAN_CONTROL_TOKEN`.

### Limites actuelles

* Le serveur HTTP n'implémente pas d'authentification avancée et nécessite une configuration manuelle pour TLS (certificat auto-signé généré par défaut).
* Les logs sont affichés en lecture seule et limités aux derniers ~4 Ko de chaque fichier.
* L'édition YAML s'appuie sur la validation syntaxique côté serveur (erreur renvoyée si invalide).

Requirements:
* Linux
* jackett: https://github.com/Jackett/Jackett
* mediainfo
* ffmpeg
* mkvmerge
* MakeMKV

TODO:
* General
    * Parse YAML template file and alert in case of errors
    * Rename all command line function arguments to append suffix indicating type (like "no_prompt_int") to allow dynamic configuration. Arguments should be suffixed on the fly in args dispatch gem
    * Web UI/GUI with assisted configuration
    * Automatically check for new commits on master and auto-update (as a task)
    * Install external requirements like chromium from inside the application
    * Restart daemon
    * Make it cross-platform
    * Trackers as templates
    
* Movies
    * Automatically watch future movies releases and add them to watchlist based on criteria (genres,?)

* Torrent search:
    
* TvSeries:
    
* Library:
    * Better management of languages
    * Automatic subtitling for videos. based on https://github.com/agermanidis/autosub (when technology will be good enough, or as a good AI project)
    * Use alternative sources to identify series
    * Do not count as duplicates if languages differ