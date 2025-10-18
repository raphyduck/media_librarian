#!/usr/bin/env bash
set -euo pipefail

# ----------------------------------------
# 1) Détection du gestionnaire de paquets
# ----------------------------------------
if   command -v pacman   &>/dev/null; then PKG="pacman"
elif command -v apt-get  &>/dev/null; then PKG="apt"
elif command -v dnf      &>/dev/null; then PKG="dnf"
elif command -v yum      &>/dev/null; then PKG="yum"
else
  echo "Erreur : gestionnaire de paquets non supporté." >&2
  echo "Installe manuellement : flac, lame, mediainfo, ffmpeg-full, mkvtoolnix, MakeMKV" >&2
  exit 1
fi

# ----------------------------------------
# 2) Installation des paquets système
# ----------------------------------------
install_sys_deps() {
  case "$PKG" in
    pacman)
      echo "→ Installation de flac, lame, mediainfo et mkvtoolnix avec pacman…"
      sudo pacman -Sy --needed --noconfirm flac lame mediainfo mkvtoolnix

      echo "→ Installation de ffmpeg-full (AUR) avec trizen…"
      if command -v trizen &>/dev/null; then
        sudo trizen -S --noconfirm ffmpeg-full
      else
        echo "⚠️  trizen introuvable : installez d’abord un helper AUR (trizen, yay…) pour pouvoir installer ffmpeg-full." >&2
      fi
      ;;
    apt)
      sudo apt-get update
      sudo apt-get install -y flac lame mediainfo ffmpeg mkvtoolnix
      ;;
    dnf)
      sudo dnf install -y flac lame-tools mediainfo ffmpeg mkvtoolnix
      ;;
    yum)
      sudo yum install -y flac lame mediainfo ffmpeg mkvtoolnix
      ;;
  esac

  # MakeMKV n'est pas dans les dépôts officiels
  if ! command -v makemkvcon &>/dev/null; then
    echo
    echo "⚠️  MakeMKV introuvable :"
    case "$PKG" in
      pacman)
        echo "   Installez makemkv-bin depuis l'AUR :  trizen -S makemkv-bin"
        ;;
      *)
        echo "   Téléchargez-le depuis https://www.makemkv.com/download/ et installez makemkv-bin"
        ;;
    esac
    echo
  fi
}

# ----------------------------------------
# 3) Installation des gems Ruby
# ----------------------------------------
install_ruby_deps() {
  # Installer Bundler 2.3.22 si nécessaire
  if ! gem list bundler -i --version ">= 2.3.22" &>/dev/null; then
    echo "→ Installation de Bundler 2.3.22…"
    gem install bundler:2.3.22
  fi

  # Installer les gems en local
  bundle config set deployment 'true'
  bundle install --jobs 4 --retry 3
}

# ----------------------------------------
# 4) Exécution
# ----------------------------------------
echo "==> Installation des dépendances système avec $PKG…"
install_sys_deps

echo "==> Installation des dépendances Ruby…"
install_ruby_deps

echo
echo "✅  Tout est prêt !"
echo "Pour lancer :"
echo "  bundle exec ruby librarian.rb --config ~/.medialibrarian/settings.yml"
