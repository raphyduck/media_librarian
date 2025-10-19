# media_librarian

WARNING: This is beta software. It might not work as intended.

What is it?
This program is made to answer my various needs for automation in the management of video media collections.

## Contrôle HTTP et interface web

Le démon expose un serveur HTTP léger (WEBrick) permettant de piloter les jobs, consulter les logs et éditer les fichiers de configuration YAML. Une interface web statique est disponible à l'adresse racine `/` et consomme les endpoints JSON (`/status`, `/logs`, `/config`, `/scheduler`).

### Lancement

1. Démarrer le démon (ex. `bundle exec ruby librarian.rb daemon start`).
2. Par défaut le serveur écoute sur `127.0.0.1:8888` (configurable via `MediaLibrarian.application.api_option`).
3. Ouvrir un navigateur sur `http://127.0.0.1:8888/` pour accéder au tableau de bord.

### Protection des écritures

Les opérations d'écriture (`PUT /config`, `PUT /scheduler`, `POST /config/reload`, `POST /scheduler/reload`, `POST /jobs`) acceptent un jeton via l'en-tête `X-Control-Token` (ou le paramètre `token`). Le tableau de bord propose un champ "Jeton de contrôle" qui enregistre localement la valeur et l'envoie automatiquement lors des sauvegardes.

Définir le jeton en amont via :

```bash
export MEDIA_LIBRARIAN_CONTROL_TOKEN="super-secret"
bundle exec ruby librarian.rb daemon start
```

Il est également possible de fournir `control_token` dans `MediaLibrarian.application.api_option` avant le démarrage du serveur.

### Limites actuelles

* Le serveur HTTP n'implémente pas d'authentification avancée ni de chiffrement TLS.
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