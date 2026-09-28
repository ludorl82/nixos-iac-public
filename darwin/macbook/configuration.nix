## macbook -- MacBook Air M2, 24 Go, the one host in the fleet that is not
## NixOS. Bought second-hand on 2026-09-21 to replace the XPS 13 Plus, whose
## display cable broke.
##
## Switched by hand, comin has no darwin equivalent:
##   darwin-rebuild switch --flake ~/git/ludorl82/nixos-iac#macbook
##
## This file is the SYSTEM half. The dotfiles and the user environment live in
## home.nix next to it.
{ pkgs, ... }:

let
  # Alacritty, avec la clef qui lui permet de DEMANDER l'acces au reseau local.
  #
  # Constate le 2026-09-23 : depuis Alacritty, `ping 203.0.113.134` repondait
  # « sendto: No route to host » a 100 %, pendant que le MEME ping lance par
  # sshd, sur la meme machine a la meme seconde, passait a 0 % de perte.
  # Meme noyau, memes routes, meme table ARP : c'est la confidentialite
  # « Reseau local » de macOS qui refusait, par application.
  #
  # Et elle refusait EN SILENCE parce que l'Info.plist livre par Alacritty ne
  # porte pas NSLocalNetworkUsageDescription. Sans cette clef, macOS ne montre
  # jamais la demande de permission : il refuse, et l'erreur qui en sort
  # ressemble a une panne de routage. Le correctif ajoute la clef ; au premier
  # lancement macOS pose enfin la question.
  #
  # La signature Nix est ad hoc : chaque reconstruction d'Alacritty est une
  # « nouvelle » application pour macOS, qui redemandera. C'est voulu --
  # redemander vaut mieux que refuser sans rien dire.
  #
  # Le grep final fait ECHOUER la construction si la clef n'est pas posee,
  # par exemple si le fichier change de forme en amont : un correctif qui
  # cesse de s'appliquer ne doit pas passer inapercu. Et la clef n'est ajoutee
  # que si elle manque, pour le jour ou Alacritty la livrera lui-meme.
  alacritty = pkgs.alacritty.overrideAttrs (old: {
    postPatch = (old.postPatch or "") + ''
      plist=extra/osx/Alacritty.app/Contents/Info.plist
      if ! grep -q NSLocalNetworkUsageDescription "$plist"; then
        sed -i '0,/<dict>/s|<dict>|<dict>\n  <key>NSLocalNetworkUsageDescription</key>\n  <string>Les commandes du terminal, comme ssh et ping, joignent les machines du reseau local.</string>|' "$plist"
      fi
      grep -q NSLocalNetworkUsageDescription "$plist"
    '';
  });
in
{
  # L'autorite privee du labo, pki.example.com, qui signe le *.lab.example de
  # kuma, grafana, frigate et les autres. LE MEME module que les treize hotes
  # NixOS : nix-darwin offre la meme option security.pki.certificateFiles,
  # alors il n'y a qu'une source pour tout le parc.
  #
  # Ce module ne nourrit QUE le paquet de certificats de Nix
  # (/etc/ssl/certs/ca-certificates.crt, NIX_SSL_CERT_FILE), celui des outils
  # installes par Nix. macOS a un SECOND magasin, le trousseau Systeme, que
  # lisent Chrome, Safari et le curl d'Apple : voir la fin de postActivation.
  imports = [ ../../modules/private-ca.nix ];

  # Reserved DHCP addresses on the LAN (pfSense, 2026-09-21):
  #   203.0.113.37  wifi en0        02:00:00:00:00:01
  #   203.0.113.38  filaire ASIX    02:00:00:00:00:01
  # Both carry a DNS override to pfSense so the private .lab.example zone
  # resolves; the rest of the LAN deliberately keeps the ISP resolvers.
  networking.hostName = "macbook";
  networking.computerName = "macbook";

  nixpkgs.hostPlatform = "aarch64-darwin";
  system.stateVersion = 5;

  # Nix itself is installed and managed by the Determinate installer, which
  # runs its own daemon. nix-darwin refuses to activate while it also thinks
  # it owns the installation, so hand it over -- the activation aborts
  # outright otherwise, which is how this first landed. The cost is that the
  # `nix.*` options are unavailable here; Determinate already enables flakes,
  # so nothing is lost in practice.
  nix.enable = false;

  users.users.ludorl82 = {
    name = "ludorl82";
    home = "/Users/ludorl82";
  };

  # Activation runs as root since nix-darwin made multi-user first class, so
  # anything that is per-user -- the homebrew module and every
  # system.defaults key below -- needs to be told WHICH user. Without this the
  # build refuses outright, which is how the first build here failed.
  system.primaryUser = "ludorl82";

  # The command-line fleet toolbox. GUI apps are NOT here: casks below.
  environment.systemPackages = with pkgs; [
    git tmux neovim fzf ripgrep fd jq yq wget tree htop
    coreutils gnused gnupg rsync
    kubectl kubernetes-helm opentofu awscli2 gh
    nodejs python3 asciinema tmuxinator
    # The terminal itself, from nixpkgs rather than a Homebrew cask.
    alacritty
  ];

  programs.zsh.enable = true;

  # Homebrew, declared. nix-darwin does not install the casks itself, it
  # drives brew -- which is the right tool for macOS GUI apps, where nix
  # packaging is patchy. brew itself must already exist: the bootstrap
  # installs it once, this only keeps the list in sync.
  #
  # onActivation.cleanup = "zap" means a cask removed from this list is
  # removed from the machine. That is the point of declaring it.
  homebrew = {
    enable = true;
    onActivation = {
      autoUpdate = true;
      upgrade = true;
      cleanup = "zap";
    };
    casks = [
      # alacritty is NOT here: Homebrew disabled the cask on 2026-09-01
      # because it stopped passing the macOS Gatekeeper check, and a failed
      # cask aborts the whole activation -- which is how home-manager silently
      # never ran the first time. It comes from nixpkgs below instead.
      "keepassxc"
      "google-chrome"
      "google-drive"
      # Claude, les deux moities : l'application de bureau et l'outil en
      # ligne de commande. « Installer Claude » pouvait vouloir dire l'un ou
      # l'autre ; retirer une ligne ici suffit a s'en defaire, le zap plus
      # haut la desinstallera.
      "claude"
      # claude-code vient de Homebrew et NON de nixpkgs, bien que nixpkgs
      # l'ait aussi. L'outil se met a jour tout seul, et un chemin du store
      # Nix est en lecture seule : la mise a jour echouerait a chaque fois.
      # Le cask, lui, suit le onActivation.upgrade declare plus haut et
      # repart a jour a chaque bascule.
      "claude-code"
      # Steam, pour jouer sur le Mac ou recevoir les jeux des machines de jeu
      # du labo par Steam Remote Play. Cask verifie actif le 2026-09-24 (un
      # cask desactive ferait echouer toute la bascule, voir plus haut).
      "steam"
      # TigerVNC, pour les consoles QEMU des VM de gaming-01 : arcade1
      # (gaming-01.lab.example:5901), arcade2 (:5902) et win11 (:5903), sans mot de
      # passe, reseau local et VPN seulement. Pas le Partage d'ecran de macOS :
      # TigerVNC parle l'extension clavier de QEMU (touches brutes), donc le
      # clavier canadien francais arrive tel quel dans l'invite. Cask verifie
      # actif le 2026-09-26 ; il s'appelle « tigervnc », plus « tigervnc-viewer ».
      "tigervnc"
    ];
  };

  # La police que reclame la configuration Alacritty du depot partage,
  # « Hack Nerd Font Mono ». Sans elle Alacritty se plaint au demarrage et
  # retombe sur une police de secours, ce qui fait disparaitre les icones du
  # prompt -- les glyphes Nerd ne sont dans aucune police livree par macOS.
  fonts.packages = [ pkgs.nerd-fonts.hack ];

  # The few macOS defaults worth pinning. Everything else stays stock.
  system.defaults = {
    NSGlobalDomain = {
      # A key held down repeats, it does not open the accent menu. The single
      # most useful default for anyone who lives in vim bindings.
      ApplePressAndHoldEnabled = false;
      InitialKeyRepeat = 15;
      KeyRepeat = 2;
      AppleShowAllExtensions = true;
      "com.apple.swipescrolldirection" = false;
    };
    dock = {
      autohide = true;
      show-recents = false;
      mru-spaces = false;
      # Apple's own apps CANNOT be removed: Safari, Mail, Calendar and the
      # rest live on the signed system volume, sealed cryptographically, and
      # deleting them would break the seal and stop the machine booting. What
      # can be done is declaring the Dock to hold exactly what is wanted --
      # everything else simply stops being one click away.
      persistent-apps = [
        "/Applications/Nix Apps/Alacritty.app"
        "/Applications/Google Chrome.app"
        "/Applications/KeePassXC.app"
        "/Applications/Claude.app"
        # Chemins fixes des casks du meme nom plus bas (steam, tigervnc).
        "/Applications/Steam.app"
        "/Applications/TigerVNC.app"
      ];
      persistent-others = [ ];
    };
    finder = {
      FXPreferredViewStyle = "Nlsv";
      ShowPathbar = true;
    };
    screencapture.location = "~/Pictures/captures";
  };

  # Touch ID instead of a typed password for sudo. `reattach` is what makes it
  # work INSIDE tmux: a process there is detached from the GUI session, so the
  # sensor is never asked and you silently fall back to typing. Since most of
  # the work on this machine happens in tmux, the option is the point rather
  # than a refinement.
  # Sur batterie : l'ecran s'eteint apres 10 minutes et la machine se met en
  # veille apres 30 (2026-09-26 ; avant : ecran 5 min, et une veille de la
  # machine a 1 minute, le defaut de macOS jamais touche).
  # `power.sleep.display` de nix-darwin existe mais s'applique aux deux
  # sources d'alimentation a la fois (`pmset -a`), alors que la demande
  # distingue la batterie du secteur -- d'ou pmset -b, qui sait le faire.
  system.activationScripts.postActivation.text = ''
    echo "reglage de la veille sur batterie (ecran 10 min, machine 30 min)..." >&2
    /usr/bin/pmset -b displaysleep 10 sleep 30

    # Branche au secteur, la machine ne se met jamais en veille (-c : secteur
    # seulement). L'ecran s'eteint quand meme apres son delai; sur batterie,
    # rien ne change. Capot ferme sans ecran externe, macOS dort malgre tout.
    echo "pas de veille de la machine sur secteur..." >&2
    /usr/bin/pmset -c sleep 0

    # Signer Alacritty COMME UN PAQUET, sous son vrai identifiant.
    #
    # Nix signe le binaire, ad hoc, sous le nom « alacritty », et ne signe
    # jamais le paquet .app. L'Info.plist dit pourtant « org.alacritty », et
    # c'est sous ce nom que macOS enregistre la permission Reseau local. Le
    # processus en cours ne pouvait donc pas etre relie a la permission
    # accordee : « No route to host » vers le LAN depuis Alacritty, meme
    # interrupteur active, meme apres redemarrage.
    #
    # Prouve le 2026-09-23 sur une copie : signee par
    # `codesign --deep --sign - --identifier org.alacritty`, elle pingue a
    # 0 % de perte sans meme redemander, reconnue par l'entree existante.
    #
    # Refait a CHAQUE activation : nix-darwin recopie l'application a chaque
    # changement, et la signature partirait avec. La signature reste ad hoc,
    # donc son empreinte change a chaque version d'Alacritty ; c'est
    # l'identifiant, stable, qui fait que la permission survit. macOS l'a
    # d'ailleurs note dans l'entree : AllowEmptyDesignatedRequirement = true.
    #
    # L'echec est BRUYANT : une signature ratee ne casse rien d'autre, mais
    # elle rendrait le reseau local muet dans Alacritty sans que rien ne dise
    # pourquoi -- exactement la panne qui a coute deux heures.
    # Faire confiance a l'autorite privee dans le TROUSSEAU SYSTEME, le magasin
    # de Chrome, Safari et du curl d'Apple. Le module private-ca.nix, importe
    # plus haut, ne couvre que les outils installes par Nix.
    #
    # Constate le 2026-09-23 : `curl https://kuma.lab.example` repondait
    # « (60) unable to get local issuer certificate », la racine absente des
    # deux trousseaux, et `security verify-cert` la disait NOT_TRUSTED.
    #
    # IDEMPOTENT par le RESULTAT et non par la presence : on ne pose la
    # confiance que si macOS ne reconnait pas deja la racine. C'est ce qui evite
    # de la redemander a chaque bascule.
    #
    # macOS exige une AUTORISATION pour changer la confiance du domaine
    # administrateur, meme en root : au premier passage, une fenetre demande ton
    # mot de passe ou Touch ID. Par SSH, sans session graphique, ca echoue, et
    # l'echec le dit au lieu de passer en silence.
    cert=${../../modules/pki.example.com.crt}
    if ! /usr/bin/security verify-cert -c "$cert" -p basic >/dev/null 2>&1; then
      echo "confiance a l'autorite privee pki.example.com..." >&2
      /usr/bin/security add-trusted-cert -d -r trustRoot \
        -k /Library/Keychains/System.keychain "$cert" \
        && /usr/bin/security verify-cert -c "$cert" -p basic >/dev/null 2>&1 \
        || echo "  ! confiance a pki.example.com NON posee : Chrome, Safari et le curl d'Apple refuseront les *.lab.example" >&2
    fi

    app="/Applications/Nix Apps/Alacritty.app"
    if [ -d "$app" ]; then
      echo "signature d'Alacritty sous org.alacritty..." >&2
      chmod -R u+w "$app"
      if /usr/bin/codesign --force --deep --sign - --identifier org.alacritty "$app" 2>/dev/null \
         && /usr/bin/codesign -dv "$app" 2>&1 | grep -qx 'Identifier=org.alacritty'; then
        :
      else
        echo "  ! signature d'Alacritty ECHOUEE : le reseau local restera bloque dans Alacritty" >&2
      fi
    fi
  '';

  security.pam.services.sudo_local = {
    enable = true;
    touchIdAuth = true;
    reattach = true;
  };
}
