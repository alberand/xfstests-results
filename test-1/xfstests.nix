{xfstests-configs}: {
  lib,
  pkgs,
  config,
  ...
}:
with lib; let
  cfg = config.programs.xfstests;
  xfstests-overlay-remote = final: prev: rec {
    xfstests-hooks = pkgs.stdenv.mkDerivation {
      name = "xfstests-hooks";
      src = cfg.hooks;
      phases = ["unpackPhase" "installPhase"];
      installPhase = ''
        runHook preInstall

        mkdir -p $out/lib/xfstests/hooks
        cp --no-preserve=mode -r $src/* $out/lib/xfstests/hooks

        runHook postInstall
      '';
    };
    xfstests = pkgs.symlinkJoin {
      name = "xfstests";
      paths =
        [
          (prev.xfstests.overrideAttrs (prev: {
            src =
              if (cfg.src != null)
              then cfg.src
              else prev.src;
            version = "git";
            patchPhase = builtins.readFile ./patchPhase.sh + prev.patchPhase;
            patches =
              (prev.patches or [])
              ++ [
                ./0001-common-link-.out-file-to-the-output-directory.patch
                ./0002-common-fix-linked-binaries-such-as-ls-and-true.patch
              ];
            wrapperScript = with pkgs;
              writeScript "xfstests-check" (''
                  #!${pkgs.runtimeShell}
                  set -e
                  export RESULT_BASE="$(pwd)/results"

                  dir=$(mktemp --tmpdir -d xfstests.XXXXXX)
                  trap "rm -rf $dir" EXIT

                  chmod a+rx "$dir"
                  cd "$dir"
                  for f in $(cd @out@/lib/xfstests; echo *); do
                    ln -s @out@/lib/xfstests/$f $f
                  done
                ''
                + (optionalString (cfg.hooks != null) ''
                  ln -s ${pkgs.xfstests-hooks}/lib/xfstests/hooks hooks
                '')
                + ''
                  export PATH=${lib.makeBinPath [
                    acl
                    attr
                    bc
                    e2fsprogs
                    fio
                    gawk
                    keyutils
                    libcap
                    lvm2
                    perl
                    procps
                    killall
                    quota
                    util-linux
                    which
                    xfsprogs
                  ]}:$PATH
                  exec ./check "$@"
                '');
          }))
        ]
        ++ optionals (cfg.hooks != null) [
          xfstests-hooks
        ];
    };
  };
in {
  options.programs.xfstests = {
    enable = mkEnableOption {
      name = "xfstests";
      default = true;
      example = true;
    };

    arguments = mkOption {
      description = "command line arguments for xfstests";
      default = "";
      example = "-g auto";
      type = types.str;
    };

    sharedir = mkOption {
      description = "path to the share directory inside VM";
      default = "/root/vmtest";
      example = "/root/vmtest";
      type = types.str;
    };

    test-dev = mkOption {
      description = "Path to disk used as TEST_DEV";
      default = "";
      example = "/dev/sda";
      type = types.str;
    };

    scratch-dev = mkOption {
      description = "Path to disk used as SCRATCH_DEV";
      default = "";
      example = "/dev/sdb";
      type = types.str;
    };

    testconfig = mkOption {
      description = "xfstests configuration file";
      default = "${xfstests-configs.xfstests-all}";
      example = "./local.config.example";
      type = types.path;
    };

    autoshutdown = mkOption {
      description = "autoshutdown machine after test is complete";
      default = false;
      example = false;
      type = types.bool;
    };

    pre-test-hook = mkOption {
      description = "bash script run before test execution";
      default = "";
      example = "trace-cmd start -e xfs";
      type = types.str;
    };

    post-test-hook = mkOption {
      description = "bash script run after test execution";
      default = "";
      example = "trace-cmd stop; trace-cmd show > /root/trace.log";
      type = types.str;
    };

    hooks = mkOption {
      description = "Path to hooks folder. 20210722064725.3077558-1-david@fromorbit.com";
      default = null;
      example = "./xfstests-hooks";
      type = types.nullOr types.path;
    };

    mkfs-cmd = mkOption {
      description = "mkfs command to recreate the disks before tests";
      default = "${pkgs.xfsprogs}/bin/mkfs.xfs";
      example = "${pkgs.xfsprogs}/bin/mkfs.xfs";
      type = types.str;
    };

    mkfs-opt = mkOption {
      description = "Options for mkfs-cmd";
      default = "-f";
      example = "-f";
      type = types.str;
    };

    src = mkOption {
      type = types.nullOr types.package;
      default = pkgs.fetchgit {
        url = "git://git.kernel.org/pub/scm/fs/xfs/xfstests-dev.git";
        rev = "v2024.12.22";
        sha256 = "sha256-xZkCZVvlcnqsUnGGxSFqOHoC73M9ijM5sQnnRqamOk8=";
      };
    };
  };

  config = mkIf cfg.enable {
    nixpkgs.overlays = [
      xfstests-overlay-remote
    ];

    environment.systemPackages = with pkgs; [
      xfstests
      xfsprogs
    ];

    # Setup envirionment
    environment.variables = {
      HOST_OPTIONS =
        pkgs.writeText "xfstests.config"
        (builtins.readFile cfg.testconfig);
    };

    users = {
      users = {
        fsgqa = {
          isNormalUser = true;
          description = "Test user";
          uid = 2000;
          group = "fsgqa";
        };

        fsgqa2 = {
          isNormalUser = true;
          description = "Test user";
          uid = 2001;
          group = "fsgqa2";
        };

        fsgqa-123456 = {
          isNormalUser = true;
          description = "Test user";
          uid = 2002;
          group = "fsgqa-123456";
        };
      };

      groups = {
        fsgqa = {
          gid = 2000;
          members = ["fsgqa"];
        };

        fsgqa2 = {
          gid = 2001;
          members = ["fsgqa2"];
        };

        fsgqa-123456 = {
          gid = 2002;
          members = ["fsgqa-123456"];
        };
      };
    };

    systemd.tmpfiles.rules = [
      "d /mnt 1777 root root"
      "d /mnt/test 1777 root root"
      "d /mnt/scratch 1777 root root"
    ];

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
      unitConfig = {
        ConditionPathExists = "${cfg.sharedir}/vmtest.toml";
      };
      after = ["network.target" "network-online.target" "local-fs.target"];
      wants = ["network.target" "network-online.target" "local-fs.target"];
      wantedBy = ["multi-user.target"];
      postStop =
        ''
          ${cfg.post-test-hook}
          # Beep beep... Human... back to work
          echo -ne '\007'
        ''
        + optionalString cfg.autoshutdown ''
          # Auto poweroff
          ${pkgs.systemd}/bin/systemctl poweroff;
        '';
      script = ''
        ${cfg.pre-test-hook}

        function get_config {
          ${pkgs.tomlq}/bin/tq --file ${cfg.sharedir}/vmtest.toml $@
        }

        if [ "$(get_config 'xfstests.args')" == "" ] && [ "${cfg.arguments}" == "" ]; then
          echo "No tests to run according to ${cfg.sharedir}/vmtest.toml"
          exit 0
        fi

        arguments=""
        if [ "$(get_config 'xfstests.args')" != "" ]; then
          arguments="$(get_config 'xfstests.args')"
        else
          arguments="${cfg.arguments}"
        fi;

        mkfs_opts=""
        if [ "$(get_config 'xfstests.mkfs_opts')" != "" ]; then
          mkfs_opts="$(get_config 'xfstests.mkfs_opts')"
        else
          mkfs_opts="${cfg.mkfs-opt}"
        fi;

        test_dev=""
        if [ "$(get_config 'xfstests.test_dev')" != "" ]; then
          test_dev="$(get_config 'xfstests.test_dev')"
        else
          test_dev="${cfg.test-dev}"
        fi;

        scratch_dev=""
        if [ "$(get_config 'xfstests.scratch_dev')" != "" ]; then
          scratch_dev="$(get_config 'xfstests.scratch_dev')"
        else
          scratch_dev="${cfg.scratch-dev}"
        fi;

        if ${pkgs.util-linux}/bin/mountpoint /mnt/test; then
          ${pkgs.util-linux}/bin/umount $test_dev
        fi
        if ${pkgs.util-linux}/bin/mountpoint /mnt/scratch; then
          ${pkgs.util-linux}/bin/umount $scratch_dev
        fi
        ${cfg.mkfs-cmd} $mkfs_opts -L test $test_dev
        ${cfg.mkfs-cmd} $mkfs_opts -L scratch $scratch_dev

        export TEST_DEV="$test_dev"
        export SCRATCH_DEV="$scratch_dev"
        export PATH="${cfg.sharedir}/bin:$PATH"
        ${pkgs.bash}/bin/bash -lc \
          "${pkgs.xfstests}/bin/xfstests-check -d $arguments"
      '';
    };
  };
}
