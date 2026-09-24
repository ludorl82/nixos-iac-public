## macbook -- the USER half. home-manager owns everything the bash scripts
## used to copy and symlink: shell, prompt, tmux, git, fzf.
##
## The shell configs themselves still live in the .shell-configs repo, which
## the console container and the work Mac also read. They are pulled in as
## files rather than rewritten as Nix expressions, so there stays ONE source
## of truth for the prompt and the keybindings -- rewriting them here would
## mean maintaining the same prompt twice.
{ config, pkgs, lib, ... }:

let
  shellConfigs = "${config.home.homeDirectory}/.shell-configs";
in
{
  home.username = "ludorl82";
  home.homeDirectory = "/Users/ludorl82";
  home.stateVersion = "26.05";

  programs.home-manager.enable = true;

  programs.zsh = {
    enable = true;
    autosuggestion.enable = true;
    syntaxHighlighting.enable = true;
    history = {
      size = 50000;
      save = 50000;
      ignoreDups = true;
      share = true;
    };
    # The prompt, sourced from the shared repo rather than redeclared.
    initContent = ''
      [ -f ${shellConfigs}/.console.p10k.zsh ] && source ${shellConfigs}/.console.p10k.zsh
      [ -f ${shellConfigs}/.console.aliases.sh ] && source ${shellConfigs}/.console.aliases.sh
      [ -f ${shellConfigs}/.console.bindings.zsh ] && source ${shellConfigs}/.console.bindings.zsh
    '';
  };

  programs.starship.enable = false;

  programs.tmux = {
    enable = true;
    mouse = true;
    keyMode = "vi";
    historyLimit = 50000;
    plugins = with pkgs.tmuxPlugins; [ yank ];
    extraConfig = ''
      # Same keys as the console container, same file.
      source-file -q ${shellConfigs}/.console.tmux.keys.conf
    '';
  };

  programs.fzf = {
    enable = true;
    enableZshIntegration = true;
  };

  programs.git = {
    enable = true;
    settings = {
      user.name = "ludorl82";
      init.defaultBranch = "main";
      pull.ff = "only";
      push.autoSetupRemote = true;
    };
  };

  programs.neovim = {
    enable = true;
    defaultEditor = true;
    viAlias = true;
    vimAlias = true;
  };

  # Le terminfo d'Alacritty. macOS n'en livre aucun, alors le shell criait
  # « can't find terminal definition for alacritty » a chaque ouverture, une
  # ligne par script de demarrage, et le terminal retombait sur des capacites
  # minimales.
  #
  # Pose dans ~/.terminfo plutot que par TERMINFO_DIRS : les messages
  # venaient de set-environment et de hm-session-vars.sh, qui SONT les
  # fichiers ou une variable d'environnement serait definie -- trop tard pour
  # eux. ~/.terminfo est consulte par ncurses sans qu'aucune variable ne soit
  # necessaire.
  #
  # Le paquet nix est deja dans la disposition hexadecimale que ncurses de
  # macOS attend (61 pour « a »), donc un lien suffit, sans recompilation.
  home.file.".terminfo/61/alacritty".source =
    "${pkgs.alacritty.terminfo}/share/terminfo/61/alacritty";
  home.file.".terminfo/61/alacritty-direct".source =
    "${pkgs.alacritty.terminfo}/share/terminfo/61/alacritty-direct";

  # Alacritty: the config file is the laptop variant already in the repo,
  # linked rather than copied so an edit there lands without a rebuild.
  home.file.".config/alacritty/alacritty.toml".source =
    config.lib.file.mkOutOfStoreSymlink "${shellConfigs}/.laptop.alacritty.toml";

  # Les projets tmuxinator, meme depot et meme procede que la ligne ci-dessus.
  # upgrade_mac.sh les rsyncait sur l'ancien Mac ; la conversion a nix-darwin
  # n'a pas repris l'etape, alors ~/.config/tmuxinator est reste vide et
  # `mux console` repondait « Could not find command console ». Lie et non
  # copie : un projet modifie dans le depot vaut sans reconstruire.
  home.file.".config/tmuxinator".source =
    config.lib.file.mkOutOfStoreSymlink "${shellConfigs}/.console.config/tmuxinator";

  # Fleet access. The jumphost is pi-02; every host answers by name on the
  # private zone, which resolves because the DHCP reservation for this Mac
  # overrides DNS to pfSense.
  programs.ssh = {
    enable = true;
    # The defaults home-manager used to inject are going away; declare only
    # what this machine needs.
    enableDefaultConfig = false;
    settings = {
      "gpu-01 srv-01 gpu-02 console-vm gaming-01" = {
        user = "ludorl82";
        hostname = "%h.lab.example";
      };
      # Home Assistant, par son module SSH. A part des autres pour deux
      # raisons : le nom d'usager est accepte tel quel et la session atterrit
      # en root dans le conteneur core-ssh, pas sur un compte du systeme ;
      # et il remplace « assistant », un nom retire qui ne resout plus nulle
      # part et qui trainait ici en pointant dans le vide.
      "ha-01" = {
        user = "ludorl82";
        hostname = "ha-01.lab.example";
      };
      "pi-01 pi-02 vm-01 vm-02 vm-03" = {
        user = "ludorl82";
        hostname = "%h.lab.example";
      };
      "jumphost" = {
        user = "ludorl82";
        hostname = "pi-02.lab.example";
      };
      "cloud-01" = {
        user = "ludorl82";
        hostname = "cloud-01.example.com";
      };
      "router" = {
        user = "admin";
        hostname = "router.lab.example";
      };
      # Le conteneur console, sur console-vm. Il ecoute sur 2222, l'image
      # publiant 2222:22.
      #
      # L'ADRESSE EST ECRITE EN CLAIR, ET C'EST VOULU. console-vm est
      # bi-residente : 192.0.2.136 sur le VLAN 10, et 203.0.113.136 sur le
      # meme sous-reseau que ce Mac. « console-vm.lab.example » ne resout QUE la
      # premiere, que ce Mac ne route pas -- ni ping, ni 22, ni 2222. La
      # seconde repond aux trois. Mesure, pas supposition.
      #
      # Un nom DNS pour cette patte serait plus propre qu'une adresse en dur
      # et reglerait le probleme a la source ; il n'en existe aucun
      # aujourd'hui, et le creer se fait dans pfSense, pas ici.
      "console" = {
        user = "ludorl82";
        hostname = "203.0.113.136";
        port = 2222;
      };
      # Les deux fichiers de clefs d'hote : celui que ssh nourrit lui-meme et
      # celui declare plus bas.
      "*" = {
        userKnownHostsFile = "~/.ssh/known_hosts ~/.ssh/known_hosts.declared";
      };
    };
  };

  # Clefs d'hote declarees plutot que decouvertes a la premiere connexion.
  # Verifiees a la source, pas acceptees a l'aveugle : celle du jumphost
  # contre l'entree que la console lui connait deja ET contre ce que l'hote
  # presente en direct, les deux concordant ; celle du conteneur lue dans son
  # propre /etc/ssh/ssh_host_ed25519_key.pub.
  #
  # Dans un fichier A PART, jamais ~/.ssh/known_hosts : ssh ecrit lui-meme
  # dans celui-la, et home-manager ne peut pas posseder un fichier qu'un
  # autre programme modifie. UserKnownHostsFile en accepte plusieurs.
  #
  # Le port non standard s'ecrit [hote]:port. Une entree « console-vm.lab.example »
  # nue ne couvrirait QUE le port 22.
  home.file.".ssh/known_hosts.declared".text = ''
    pi-02,pi-02.lab.example ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example
    [203.0.113.136]:2222,[console-vm.lab.example]:2222 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY0000 reader@example
  '';

  # The two public repos this configuration reads from. Without them the
  # Alacritty symlink dangles and the prompt silently falls back to the
  # default -- which is exactly what happened on the first successful switch,
  # because nothing here had cloned them. Declared as an activation step so a
  # wiped machine comes back whole from darwin-rebuild alone.
  #
  # It PULLS as well as clones, and that is the whole point. Cloning only when
  # absent meant a wiped machine got the current scripts while an existing one
  # silently kept whatever was on disk -- so macKeyboard below could run a
  # months-old mac_keyboard.sh and report success. Same failure as running
  # darwin-rebuild against a stale checkout: green, complete, and applying a
  # version of the truth that expired.
  #
  # --ff-only on purpose: a divergence or an uncommitted edit must STOP the
  # update, never be merged away. Nothing here is fatal, because a work Mac
  # may block GitHub and a stale script beats a failed activation -- but
  # nothing is silent either, and the revision actually in use is printed so
  # a green activation says WHICH version ran.
  home.activation.cloneShellRepos =
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      for pair in \
        "${config.home.homeDirectory}/.shell-configs|https://github.com/ludorl82/shell-configs.git" \
        "${config.home.homeDirectory}/.shell-scripts|https://github.com/ludorl82/.shell-scripts.git"
      do
        dir="''${pair%%|*}"; url="''${pair#*|}"
        if [ -d "$dir/.git" ]; then
          $DRY_RUN_CMD ${pkgs.git}/bin/git -C "$dir" pull --ff-only --quiet \
            || echo "  ! $dir : pull refuse, la version sur disque reste en place"
        else
          $DRY_RUN_CMD ${pkgs.git}/bin/git clone --quiet "$url" "$dir" \
            || echo "  ! $dir : clone echoue"
        fi
        echo "  $dir @ $(${pkgs.git}/bin/git -C "$dir" rev-parse --short HEAD 2>/dev/null || echo inconnu)"
      done
    '';

  # KeePass par WebDAV. KeePassXC ne sait pas ouvrir une URL et n'a aucune
  # synchro distante ; le montage Finder est impossible parce qu'Apache refuse
  # PROPFIND sur la racine. kp-sync.sh dit pourquoi en detail et porte le
  # fichier a la main, en refusant d'ecraser dans les deux sens.
  #
  # Le mot de passe du gaming-01 vit dans le trousseau macOS, jamais ici :
  #   security add-generic-password -s vault.family.example -a vault-user -w
  home.packages =
    let
      kpSync = pkgs.writeShellApplication {
        name = "kp-sync";
        runtimeInputs = with pkgs; [ curl coreutils ];
        text = builtins.readFile ./kp-sync.sh;
      };
    in [
      kpSync
      (pkgs.writeShellScriptBin "kp-pull" ''exec ${kpSync}/bin/kp-sync pull "$@"'')
      (pkgs.writeShellScriptBin "kp-push" ''exec ${kpSync}/bin/kp-sync push "$@"'')
    ];

  # Raccourcis clavier macOS : touches d'edition facon Emacs, et la
  # maximisation sur Controle-Option-Commande-M. L'implementation vit dans
  # .shell-scripts et le dictionnaire dans .shell-configs, PAS ici : le Mac du
  # bureau applique exactement les memes et n'a pas Nix. Une seule source,
  # deux machines, comme pour le prompt et les raccourcis de tmux.
  home.activation.macKeyboard =
    lib.hm.dag.entryAfter [ "cloneShellRepos" ] ''
      kb="${config.home.homeDirectory}/.shell-scripts/scripts/mac_keyboard.sh"
      if [ -x "$kb" ]; then
        $DRY_RUN_CMD "$kb" >/dev/null \
          || echo "  ! mac_keyboard.sh a echoue : raccourcis NON appliques"
      else
        echo "  ! mac_keyboard.sh absent : raccourcis NON appliques"
      fi
    '';

  home.sessionVariables = {
    EDITOR = "nvim";
    LANG = "fr_CA.UTF-8";
  };
}
