# API REST et serveur MCP

Le démon expose deux interfaces sur le même port de contrôle (`listen_port` de `api.yml`) :

* **l'API REST** déjà utilisée par l'interface web (`/status`, `/jobs`, `/logs`, `/calendar`, `/watchlist`, …) ;
* **un serveur MCP** (Model Context Protocol) sur `POST /mcp`, transport *Streamable HTTP* sans état, réponses JSON.

Chaque outil MCP est une correspondance directe vers une route REST, exécutée dans le processus du démon : les deux
interfaces ne peuvent pas diverger.

## Authentification

Toutes les routes, `/mcp` compris, exigent soit la session de l'interface web, soit le jeton `api_token` de `api.yml`
(ou la variable `MEDIA_LIBRARIAN_API_TOKEN`), transmis :

* par l'en-tête `Authorization: Bearer <jeton>` (clients MCP, reverse proxy) ;
* ou par l'en-tête historique `X-Control-Token: <jeton>`.

Générer un jeton : `ruby -rsecurerandom -e 'puts SecureRandom.hex(32)'`. Ne jamais le committer.

## Outils MCP

| Outil | Rôle | Route |
|---|---|---|
| `etat` | tâches en cours / en file / terminées, files, uptime, CPU, mémoire | `GET /status` |
| `journaux` | fin des journaux, filtre texte, choix du fichier | `GET /logs` |
| `commandes` | catalogue des commandes CLI et des commandes des modèles | `GET /commands`, `/template_commands` |
| `lancer_commande` | met en file n'importe quelle commande CLI (`library process_folder`, `torrent search`, …) | `POST /jobs` |
| `tache` / `annuler_tache` | suivre (statut, progression, sortie) ou annuler une tâche | `GET` / `DELETE /jobs/<id>` |
| `redemarrer` | redémarrage propre du démon | `POST /restart` |
| `recharger` | recharge `conf.yml`, `api.yml` ou le planificateur | `POST /config/reload`, … |
| `arreter` | arrêt du démon (exige `confirmer=true`) | `POST /stop` |
| `mettre_a_jour` | `git pull` puis arrêt pour relance par le superviseur (exige `confirmer=true`) | `POST /update-stop` |
| `calendrier` | sorties suivies, filtrables (type, genres, notes, dates, déjà téléchargé, déjà dans la liste) | `GET /calendar` |
| `calendrier_chercher` | recherche d'un titre chez TMDB / Trakt / OMDB et dans le calendrier | `GET /calendar/search` |
| `calendrier_importer` | ajoute un résultat de recherche au calendrier (et à la liste d'intérêts) | `POST /calendar/import` |
| `calendrier_rafraichir` | rafraîchit le calendrier depuis les fournisseurs | `POST /calendar/refresh` |
| `liste_interets` | liste d'intérêts (watchlist) et torrents en attente associés | `GET /watchlist` |
| `liste_interets_ajouter` | ajoute des titres du calendrier par `imdb_id` (titre et type repris du calendrier) | `POST /watchlist` |
| `liste_interets_retirer` | retire un titre | `DELETE /watchlist` |
| `collection` | collection locale paginée | `GET /collection` |
| `torrents_en_attente` / `torrent_valider` / `torrent_supprimer` | file des torrents trouvés | `/torrents/*` |
| `configuration_lire` | `conf.yml`, `api.yml`, planificateur (secrets masqués) | `GET /config`, … |
| `appeler_api` | toute autre route (musique, modèles, trackers, écriture de configuration…) | toutes |

Écrire un fichier (`PUT`), `/stop` et `/update-stop` exigent `confirmer=true`. `/mcp`, `/ws` et `/session` ne sont pas
accessibles par `appeler_api`.

Exemple, ajouter à la liste d'intérêts les films de la semaine qui n'y sont pas encore :

1. `calendrier` avec `{"type": "movie", "interet": false}` ;
2. `liste_interets_ajouter` avec `{"elements": [{"imdb_id": "tt1234567"}, {"imdb_id": "tt7654321"}]}`.

## Déploiement derrière Caddy

Le démon tourne sur l'hôte ; Caddy tourne dans Docker. Deux points à régler.

### 1. Rendre le démon joignable par le conteneur Caddy, sans l'exposer sur Internet

Ne pas utiliser `bind_address: 0.0.0.0` sur une machine sans pare-feu : le port serait public. Lier le démon à
l'adresse de la passerelle du pont Docker (celle que voit le conteneur Caddy), par exemple `docker0` :

```yaml
# ~/.medialibrarian/api.yml
bind_address: 172.17.0.1      # ip -4 addr show docker0
listen_port: 8888
api_token: "<jeton>"
auth:
  username: admin
  password_hash: "$2a$12$..."
```

Le socket Unix `~/.medialibrarian/librarian.sock` reste disponible pour la CLI locale. Un démon lié hors loopback
refuse de démarrer sans authentification configurée.

Côté conteneur Caddy (`docker-compose.yml`), faire pointer `host.docker.internal` vers la passerelle :

```yaml
services:
  caddy:
    extra_hosts:
      - "host.docker.internal:host-gateway"
```

Si Caddy est sur un réseau Docker dédié (ex. `mcp_edge`), sa passerelle n'est pas `172.17.0.1` : lier le démon à
la passerelle de ce réseau (`docker network inspect mcp_edge -f '{{(index .IPAM.Config 0).Gateway}}'`) et remplacer
`host.docker.internal` par cette adresse.

### 2. Site Caddy

Accès direct (interface web, API REST et MCP avec jeton statique), à adapter au format du Caddyfile existant
(site en `http://` si le TLS est terminé en amont par nginx) :

```caddyfile
medialibrarian.example.org {
	reverse_proxy host.docker.internal:8888 {
		# WebSocket de l'interface web et réponses longues (recherches calendrier)
		transport http {
			read_timeout 180s
		}
	}
}
```

Un client MCP qui accepte un jeton statique (Claude Code, agents, planificateur) se branche alors directement :

```bash
claude mcp add --transport http media-librarian https://medialibrarian.example.org/mcp \
  --header "Authorization: Bearer <jeton>"
```

### 3. Connecteur OAuth (claude.ai) via le pont stdio

Les connecteurs claude.ai exigent OAuth. Pour réutiliser un proxy OAuth qui encapsule un serveur MCP stdio, lancer
comme serveur stdio le pont fourni, qui ne dépend que de la bibliothèque standard Ruby :

```bash
MEDIA_LIBRARIAN_URL=http://host.docker.internal:8888 \
MEDIA_LIBRARIAN_API_TOKEN=<jeton> \
ruby scripts/mcp_stdio_bridge.rb
```

Variables : `MEDIA_LIBRARIAN_URL` (défaut `http://127.0.0.1:8888`), `MEDIA_LIBRARIAN_API_TOKEN`,
`MEDIA_LIBRARIAN_TIMEOUT` (secondes, défaut 120), `MEDIA_LIBRARIAN_INSECURE=1` pour un certificat auto-signé.
Une image `ruby:3.3-alpine` avec ce seul fichier suffit. Les recherches calendrier interrogent plusieurs fournisseurs
et peuvent dépasser 30 s : relever le délai d'attente du proxy si nécessaire. Les commandes longues ne bloquent
jamais : `lancer_commande` rend immédiatement un identifiant de tâche.

## Test rapide

```bash
curl -s https://medialibrarian.example.org/mcp \
  -H "Authorization: Bearer <jeton>" -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"etat","arguments":{}}}'
```

Sans jeton, la réponse est `403 {"error":"forbidden"}`.
