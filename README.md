# media_librarian

WARNING: This is beta software. It might not work as intended.

What is it?
This program is made to answer my various needs for automation in the management of video media collections.

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