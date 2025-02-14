{
  lib,
  pkgs,
  config,
  ...
}: let 
  cfg = config.programs.uploader;
in with lib;{
  options = {
    enable = mkEnableOption {
      name = "xfstests-results";
      default = false;
      example = true;
    };

    repository = mkOption {
      description = "GitHub repository to upload results to";
      default = "";
      example = "https://github.com/alberand/xfstests-results";
      type = types.str;
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.xfstests = {
      enable = true;
      serviceConfig = {
        Type = "oneshot";
        StandardOutput = "tty";
        StandardError = "tty";
        # argh... Nix ignore SIGPIPE somewhere and it causes all child processes
        # to ignore SIGPIPE. Don't remove it or otherwise many tests will fail
        # due too Broken pipe. Test with yes | head should not return Brokne
        # pipe.
        IgnoreSIGPIPE = "no";
        User = "root";
        Group = "root";
        WorkingDirectory = "/root";
      };
      after = ["xfstests.target"];
      script = ''
        upload() {
          ${pkgs.github-uploader}/bin/github-uploader \
            ${cfg.repository} \
            /root/results/check.log
        }
        find /root/results -name 'result.xml' -exec upload {} \;
      '';
    };
  };
}
