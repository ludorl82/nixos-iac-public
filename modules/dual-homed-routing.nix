## Les reponses parties de l'adresse VLAN50 repartent par la patte VLAN50.
##
## LE PROBLEME. Neuf hotes du parc ont une patte sur chaque reseau :
## 192.0.2.N sur le VLAN10, 203.0.113.N sur le VLAN50, meme dernier octet.
## La route par defaut est sur le VLAN10 seulement (voir la ligne de base
## reseau). Quand un pair HORS des deux sous-reseaux -- cloud-01 par WireGuard, un
## autre VLAN -- joint l'adresse 203.0.113.N, pfSense lui transmet la demande
## par son interface VLAN50. La reponse, elle, part de 203.0.113.N mais suit
## la route par defaut, donc sort par le VLAN10. pfSense garde ses etats par
## interface ; il voit revenir par le VLAN10 une reponse a une demande entree
## par le VLAN50, et la jette.
##
## Mesure le 2026-09-23 depuis cloud-01, sur vm-02, vm-01 et console-vm : le ping
## passe sur les deux pattes, mais TCP ECHOUE sur toutes les pattes 50 et passe
## sur toutes les pattes VLAN10. Deja vu sur gaming-01 et le NAS en juillet, et
## sur les arcades en aout (« ping a moitie, TCP bloque »).
##
## LE CORRECTIF, ET POURQUOI IL EST ETROIT. Deux regles, pour le seul trafic
## qui part de l'adresse VLAN50 :
##
##   100  from 203.0.113.N  lookup main  suppress_prefixlength 0
##   101  from 203.0.113.N  lookup 50    (default via 203.0.113.254)
##
## La 100 consulte la table principale en IGNORANT sa route par defaut : tout
## ce qui a une route precise y reste -- le LAN en direct, les pods par
## flannel.1, docker. Seul ce qui serait tombe sur la route par defaut, donc
## sur la mauvaise patte, atteint la 101 et sort par pfSense cote VLAN50.
##
## Autrement dit, ce module ne change le chemin QUE du trafic qui echoue
## aujourd'hui. Le trafic sourcé du VLAN10 n'est pas touche, et le trafic
## que l'hote emet lui-meme vers l'exterieur non plus : il prend l'adresse
## VLAN10, celle de la route par defaut.
##
## LE PIEGE EVITE. Le correctif des arcades (fef178a) mettait dans sa table une
## route de sous-reseau et une router, rien d'autre. Sur un noeud k3s, une
## reponse vers une adresse de pod serait partie chez pfSense au lieu de
## flannel.1. C'est pour ca que la regle 100 existe ici.
##
## PREUVE, sur vm-02, regles posees a la main puis retirees :
##
##   regles posees    cloud-01 -> 203.0.113.134:22   banniere SSH recue
##   regles retirees  cloud-01 -> 203.0.113.134:22   echec
##
## et, regles posees : reponse vers un pod par flannel.1, vers le LAN en
## direct, trafic VLAN10 inchange.
## LE SECOND CAS, ajoute le 2026-09-24 : la patte VLAN10, vers le LAN.
##
## Un client SEUL sur le VLAN50 (le Mac, un telephone) qui joint le nom d'un
## hote, donc son adresse VLAN10, passe par pfSense. L'hote, lui, repondait
## DIRECTEMENT par sa patte 50, puisque 203.0.113.0/23 lui est connecte.
## pfSense ne voyait qu'un sens :
##
##   mvneta0.10  203.0.113.37 -> 192.0.2.136:22   SYN_SENT:CLOSED
##               expires in 00:00:24,  22:0 pkts
##
## 22 paquets dans un sens, zero dans l'autre. L'etat reste « en ouverture »,
## dont le delai est de 30 s, rafraichi a chaque paquet du client. Des qu'une
## session SSH se tait plus de 30 s, l'etat expire et le caractere suivant
## est jete : « la connexion gele apres une ou deux minutes ».
##
## La premiere version de ce module avait laisse ce cas dehors, EXPRES : un
## transfert de 200 Mo du Mac vers une patte VLAN10 passait. Il passait parce
## qu'il durait dix secondes, sous le delai. Un essai court ne rencontre
## jamais un delai d'inactivite.
##
## Regle ajoutee, aussi etroite que les deux autres :
##
##   102  from 192.0.2.N  to 203.0.113.0/23  lookup 10  (default via .254)
##
## Seules les REPONSES parties de l'adresse VLAN10 vers le LAN changent de
## chemin. Le trafic que l'hote emet lui-meme vers le LAN prend l'adresse
## 203.0.113.N et n'est pas touche ; VLAN10 vers VLAN10 reste direct ; les
## pods ne sont pas dans 203.0.113.0/23.
##
## Prouve a la main sur une forme de cablage chacune, ligne envoyee depuis le
## Mac apres 45 s de silence :
##
##   console-vm   10-lan     sans : gele   avec : recue   retiree : gele
##   pi-01    20-vlan10  sans : gele   avec : recue
##   srv-01  30-mvhost  sans : gele   avec : recue
## LE TROISIEME CAS, ajoute le 2026-09-24 : les reponses d'un conteneur.
##
## « ssh console-vm.lab.example -p 2222 lache apres 30 secondes pas mal
## exactement. » Le port 2222 est publie par Docker (DNAT vers
## 198.18.17.2:22). La reponse de sshd part donc de l'adresse du CONTENEUR,
## routee avant d'etre retraduite vers 192.0.2.N : la regle 102, qui
## regarde la source 192.0.2.N, ne la voit pas, et la reponse au Mac
## sortait par la patte 50. pfSense : SYN_SENT:CLOSED, 24:0 pkts.
##
## Correctif, option dnatReplies : une connexion NOUVELLE qui entre par la
## patte VLAN10 recoit une marque de connexion (0x100); les paquets qui
## sortent du pont du conteneur la reprennent; la regle 103 envoie ce qui
## est marque ET va vers le LAN dans la table 10, par pfSense. Ce que le
## conteneur ouvre lui-meme n'est jamais marque, et une reponse vers un
## hote du VLAN10 reste directe (103 ne vise que 203.0.113.0/23).
##
## Prouve a la main sur console-vm, ligne envoyee depuis le Mac apres 45 s :
##   avec la marque : ESTABLISHED:ESTABLISHED, 24:16 pkts, ligne recue
##   marque retiree : Broken pipe
##
## Les iptables vivent dans leur propre chaine, labo-dnat-mark, videe et
## remplie a chaque (re)demarrage du pare-feu : jamais de doublon. Pas
## active sur les noeuds k3s : Traefik a le meme mal en theorie, mais
## kube-proxy et flannel ont leurs propres marques, a verifier d'abord.
{ lib, config, ... }:
let
  cfg = config.labo.dualHomed;
  v50 = "203.0.113.${toString cfg.octet}";
  v10 = "192.0.2.${toString cfg.octet}";
in
{
  options.labo.dualHomed = {
    enable = lib.mkEnableOption "le routage par source pour la patte VLAN50";

    octet = lib.mkOption {
      type = lib.types.ints.between 1 254;
      description = ''
        Dernier octet de l'hote, le meme sur les deux pattes par convention :
        192.0.2.N et 203.0.113.N.
      '';
    };

    vlan50Network = lib.mkOption {
      type = lib.types.str;
      default = "20-vlan50";
      description = ''
        Nom de l'unite systemd-networkd qui porte l'adresse VLAN50. Il varie
        selon la facon dont l'hote est cable : 20-vlan50 sur les VM a deux
        cartes, 10-eno1 ou 10-end0 quand le VLAN50 est la patte non etiquetee,
        25-mvhost50 derriere un macvtap.
      '';
    };

    vlan10Network = lib.mkOption {
      type = lib.types.str;
      default = "10-lan";
      description = ''
        Nom de l'unite systemd-networkd qui porte l'adresse VLAN10, et donc la
        route vers pfSense : 10-lan sur les VM a deux cartes, 20-vlan10 quand
        le VLAN10 est une sous-interface etiquetee, 30-mvhost derriere un
        macvtap.
      '';
    };

    dnatReplies = {
      enable = lib.mkEnableOption ''
        le marquage des connexions entrees par la patte VLAN10, pour que les
        reponses d'un conteneur (port publie par DNAT) repartent par pfSense
      '';

      vlan10Interface = lib.mkOption {
        type = lib.types.str;
        example = "ens2";
        description = "Nom de l'INTERFACE (pas de l'unite) qui porte l'adresse VLAN10.";
      };

      bridges = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "docker0" ];
        description = "Ponts d'ou sortent les reponses des conteneurs.";
      };
    };
  };

  config = lib.mkMerge [ (lib.mkIf cfg.enable {
    systemd.network.networks.${cfg.vlan50Network} = {
      routes = [
        { Destination = "203.0.113.0/23"; Table = 50; }
        { Gateway = "203.0.113.254"; Table = 50; }
      ];
      routingPolicyRules = [
        # 254 est la table principale.
        { From = "${v50}/32"; Table = 254; SuppressPrefixLength = 0; Priority = 100; }
        { From = "${v50}/32"; Table = 50; Priority = 101; }
      ];
    };

    systemd.network.networks.${cfg.vlan10Network} = {
      routes = [
        { Gateway = "192.0.2.254"; Table = 10; }
      ];
      routingPolicyRules = [
        { From = "${v10}/32"; To = "203.0.113.0/23"; Table = 10; Priority = 102; }
      ];
    };
  })

  (lib.mkIf (cfg.enable && cfg.dnatReplies.enable) {
    systemd.network.networks.${cfg.vlan10Network}.routingPolicyRules = [
      { FirewallMark = "0x100/0x100"; To = "203.0.113.0/23"; Table = 10; Priority = 103; }
    ];

    networking.firewall.extraCommands = ''
      iptables -t mangle -N labo-dnat-mark 2>/dev/null || true
      iptables -t mangle -F labo-dnat-mark
      iptables -t mangle -A labo-dnat-mark -i ${cfg.dnatReplies.vlan10Interface} -m conntrack --ctstate NEW -j CONNMARK --set-xmark 0x100/0x100
      ${lib.concatMapStrings (b: ''
        iptables -t mangle -A labo-dnat-mark -i ${b} -j CONNMARK --restore-mark --nfmask 0x100 --ctmask 0x100
      '') cfg.dnatReplies.bridges}
      iptables -t mangle -C PREROUTING -j labo-dnat-mark 2>/dev/null || iptables -t mangle -A PREROUTING -j labo-dnat-mark
    '';
    networking.firewall.extraStopCommands = ''
      iptables -t mangle -D PREROUTING -j labo-dnat-mark 2>/dev/null || true
      iptables -t mangle -F labo-dnat-mark 2>/dev/null || true
      iptables -t mangle -X labo-dnat-mark 2>/dev/null || true
    '';
  }) ];
}
