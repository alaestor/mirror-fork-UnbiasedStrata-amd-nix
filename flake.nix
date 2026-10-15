{
  description = "UnbiasedStrata on AMD HIP, with pinned Qwen3.6 and Qwen3.8 workflows";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    nix-hug = {
      url = "github:longregen/nix-hug/v5.1.0";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{ flake-parts, nix-hug, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" ];
      perSystem =
        { pkgs, system, ... }:
        let
          rocm = pkgs.rocmPackages;
          launcherCommon = ./nix/launcher-common.sh;
          source = pkgs.lib.fileset.toSource {
            root = ./.;
            fileset = pkgs.lib.fileset.unions [
              ./CMakeLists.txt
              ./cmake
              ./src
              ./include
              ./frontend
              ./patches
              ./third_party/ggml
              ./tests
              ./tools
              ./data
            ];
          };
          packSource = pkgs.lib.fileset.toSource {
            root = ./.;
            fileset = pkgs.lib.fileset.unions [
              ./tools
              ./data
            ];
          };
          llamaSource = pkgs.fetchFromGitHub {
            owner = "ggml-org";
            repo = "llama.cpp";
            rev = "3cf03257f219afbe7334045ff7c6a06ac68c627d";
            hash = "sha256-SRGoXa+4ACBCB3eaG9XFYhMN1i0FyPEy9Rrer+dFGYI=";
          };
          strata = pkgs.stdenv.mkDerivation {
            pname = "unbiased-strata-hip";
            version = "0.1.39";
            src = source;
            nativeBuildInputs = [
              pkgs.cmake
              pkgs.ninja
            ];
            buildInputs = [
              rocm.clr
              rocm.hipblas
              rocm.rocblas
            ];
            postUnpack = ''
              mkdir -p "$sourceRoot/third_party/llama.cpp"
              cp -r ${llamaSource}/. "$sourceRoot/third_party/llama.cpp/"
              chmod -R u+w "$sourceRoot/third_party/llama.cpp"
            '';
            cmakeFlags = [
              "-DSTRATA_ENABLE_HIP=ON"
              "-DSTRATA_ENABLE_CUDA=OFF"
              "-DSTRATA_BUILD_TESTS=OFF"
              "-DSTRATA_PORTABLE=ON"
              "-DCMAKE_HIP_COMPILER=${rocm.clr.hipClangPath}/clang++"
              "-DCMAKE_HIP_ARCHITECTURES=gfx1100"
            ];
            buildPhase = ''
              runHook preBuild
              jobs="$NIX_BUILD_CORES"
              if [ "$jobs" -eq 0 ] || [ "$jobs" -gt 4 ]; then jobs=4; fi
              cmake --build . --target unbiased-strata strata-device native_expert_parity --parallel "$jobs"
              runHook postBuild
            '';
            installPhase = ''
              runHook preInstall
              install -Dm755 unbiased-strata "$out/bin/unbiased-strata"
              install -Dm755 strata-device "$out/bin/strata-device"
              install -Dm755 native_expert_parity "$out/bin/native_expert_parity"
              runHook postInstall
            '';
            meta = {
              description = "Strata inference engine and C++ API server, AMD HIP build";
              license = pkgs.lib.licenses.mit;
              platforms = [ "x86_64-linux" ];
              mainProgram = "unbiased-strata";
            };
          };
          modelFile = "Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf";
          modelRevision = "5bc3e238d916f48a861bac2f8a1990a0e9b7e98d";
          # Only explicit AIO outputs evaluate model downloads. LFS payloads
          # stream in builders, not the Nix evaluator (nix-hug v5 workaround).
          nixHug = import ./nix/nix-hug-streaming.nix { inherit pkgs nix-hug; };
          model = nixHug.fetchModel {
            url = "unsloth/Qwen3.6-35B-A3B-MTP-GGUF";
            rev = modelRevision;
            filters.files = [ modelFile ];
            fileTreeHash = "sha256-8gC7LFtwlOU5egKZd0KLhWskeezaMXgUJO0nJM5mSNQ=";
          };
          qwen38Shard1 = "Qwen3.8-Flash-Next-GSQ-RCO-IQ3_XXS-00001-of-00002.gguf";
          qwen38Shard2 = "Qwen3.8-Flash-Next-GSQ-RCO-IQ3_XXS-00002-of-00002.gguf";
          qwen38Model = nixHug.fetchModel {
            url = "ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF";
            rev = "ed59f92082b1e93c0e96d60a8b11aab089b52f09";
            filters.files = [
              "IQ3_XXS/${qwen38Shard1}"
              "IQ3_XXS/${qwen38Shard2}"
            ];
            fileTreeHash = "sha256-JaZvPIZPT337F//3Y+ThQmZOH3sXDGT7kPb/8BxgHnI=";
          };
          # Network access is confined to this fixed-output AIO dependency.
          qwen38MtpSource =
            pkgs.runCommand "qwen38-mtp-source"
              {
                nativeBuildInputs = [ pkgs.python3 ];
                SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
                outputHashMode = "recursive";
                outputHashAlgo = "sha256";
                outputHash = "sha256-L7XFnbscqkaWE/Striv2cjA81gE8FqpMWjt9Z7CzZ7w=";
              }
              ''
                python ${./nix/mtp-fetch-pinned.py} ${packSource}/tools fetch --out fetched
                python ${./nix/verify-mtp-source.py} fetched ${./nix/qwen38-mtp-manifest.json}
                mkdir -p "$out/tensors"
                cp ${./nix/qwen38-mtp-manifest.json} "$out/mtp-manifest.json"
                cp fetched/tensors/*.bin "$out/tensors/"
              '';
          qwen38ModelPack =
            pkgs.runCommand "qwen38-iq3-xxs-pack"
              {
                nativeBuildInputs = [ python ];
                STRATA_GGUF_PY = "${llamaSource}/gguf-py";
              }
              ''
                python ${packSource}/tools/iq_pack.py --gguf ${qwen38Model}/IQ3_XXS/${qwen38Shard1} \
                  --out "$out/pack" --expert-profile ${./data/expert-profile.bin}
                python ${packSource}/tools/mtp_pack.py --src ${qwen38MtpSource} \
                  --experts q2_0 --out mtp-q2_0.gguf
                python ${packSource}/tools/mtp_rt.py --gguf mtp-q2_0.gguf --out "$out/mtp"
                cp ${./data/draft_vocab.bin} "$out/mtp/draft_vocab.bin"
              '';
          serveQwen38Aio = pkgs.writeShellApplication {
            name = "strata-qwen38-aio";
            text = ''
              exec ${serveQwen38}/bin/strata-qwen38 \
                ${qwen38Model}/IQ3_XXS/${qwen38Shard1} ${qwen38ModelPack} "$@"
            '';
          };
          qwen38AioLauncher = pkgs.writeShellApplication {
            name = "strata-qwen38-aio";
            runtimeInputs = [ pkgs.nix ];
            text = ''
              exec nix run ${inputs.self}#legacyPackages.${system}.qwen38-aio -- "$@"
            '';
          };
          python = pkgs.python3.withPackages (ps: [
            ps.numpy
            ps.regex
            ps.pyyaml
            ps.tqdm
          ]);
          modelPack =
            pkgs.runCommand "qwen36-q4-pack"
              {
                nativeBuildInputs = [ python ];
                STRATA_GGUF_PY = "${llamaSource}/gguf-py";
              }
              ''
                mkdir -p "$out"
                python ${packSource}/tools/iq_pack.py --gguf ${model}/${modelFile} --out "$out/pack" \
                  --expert-profile ${./data/qwen36-expert-profile.bin}
                python ${packSource}/tools/mtp_qwen36_pack.py --gguf ${model}/${modelFile} --out "$out/mtp"
              '';
          serveAio = pkgs.writeShellApplication {
            name = "strata-qwen36-aio";
            extraShellCheckFlags = [ "-x" ];
            text = ''
              source ${launcherCommon}
              load_strata_env
              strata_configure_args "$@"
              exec ${strata}/bin/unbiased-strata \
                --model ${model}/${modelFile} \
                --pack ${modelPack}/pack --mtp ${modelPack}/mtp \
                "''${strata_server_args[@]}" -- "''${strata_engine_args[@]}"
            '';
          };
          aioLauncher = pkgs.writeShellApplication {
            name = "strata-qwen36-aio";
            runtimeInputs = [ pkgs.nix ];
            # Defer nix-hug evaluation until explicitly RUNNING the AIO app.
            # Ordinary flake checks and package builds must not fetch 23 GB.
            text = ''
              exec nix run ${inputs.self}#legacyPackages.${system}.qwen36-aio -- "$@"
            '';
          };
          prepareLocal = pkgs.writeShellApplication {
            name = "strata-prepare-qwen36";
            extraShellCheckFlags = [ "-x" ];
            runtimeInputs = [
              python
              pkgs.coreutils
            ];
            text = ''
              source ${launcherCommon}
              load_strata_env
              if [ "$#" -eq 2 ]; then
                STRATA_MODEL=$1
                STRATA_PREPARED_DIR=$2
              elif [ "$#" -ne 0 ]; then
                echo "usage: strata-prepare-qwen36 [MODEL.gguf OUTPUT_DIR]" >&2
                exit 2
              fi
              if [ -z "$STRATA_MODEL" ]; then
                echo "Set STRATA_MODEL in .env or pass MODEL.gguf OUTPUT_DIR" >&2
                exit 2
              fi
              model=$(realpath -- "$STRATA_MODEL")
              expected=55983c5a75a1ab969824077b3bb3de4146e82a9234072b48ad4e8f92ad3fe9f1
              actual=$(sha256sum -- "$model")
              if [ "''${actual%% *}" != "$expected" ]; then
                echo "Model SHA-256 mismatch: expected the pinned Q4_K_XL MTP file" >&2
                exit 1
              fi
              export STRATA_GGUF_PY=${llamaSource}/gguf-py
              python ${packSource}/tools/iq_pack.py --gguf "$model" --out "$STRATA_PREPARED_DIR/pack" \
                --expert-profile ${./data/qwen36-expert-profile.bin}
              python ${packSource}/tools/mtp_qwen36_pack.py --gguf "$model" --out "$STRATA_PREPARED_DIR/mtp"
            '';
          };
          serveLocal = pkgs.writeShellApplication {
            name = "strata-qwen36";
            extraShellCheckFlags = [ "-x" ];
            text = ''
              source ${launcherCommon}
              load_strata_env
              if [ "$#" -ge 2 ] && [[ "$1" != -* ]]; then
                STRATA_MODEL=$1
                STRATA_PREPARED_DIR=$2
                shift 2
              fi
              if [ -z "$STRATA_MODEL" ]; then
                echo "Set STRATA_MODEL in .env or pass MODEL.gguf PREPARED_DIR" >&2
                exit 2
              fi
              strata_configure_args "$@"
              exec ${strata}/bin/unbiased-strata --model "$STRATA_MODEL" \
                --pack "$STRATA_PREPARED_DIR/pack" --mtp "$STRATA_PREPARED_DIR/mtp" \
                "''${strata_server_args[@]}" -- "''${strata_engine_args[@]}"
            '';
          };
          prepareQwen38 = pkgs.writeShellApplication {
            name = "strata-prepare-qwen38";
            extraShellCheckFlags = [ "-x" ];
            runtimeInputs = [
              python
              pkgs.coreutils
            ];
            text = ''
              source ${launcherCommon}
              load_qwen38_env
              if [ "$#" -eq 2 ]; then
                STRATA_MODEL=$1
                STRATA_PREPARED_DIR=$2
              elif [ "$#" -ne 0 ]; then
                echo "usage: strata-prepare-qwen38 [SHARD1.gguf OUTPUT_DIR]" >&2
                exit 2
              fi
              if [ -z "$STRATA_MODEL" ] || [ -z "''${STRATA_QWEN38_MTP_SOURCE:-}" ]; then
                echo "Set STRATA_QWEN38_MODEL and STRATA_QWEN38_MTP_SOURCE to local inputs (no downloads)" >&2
                exit 2
              fi
              # Fail before hashing 76 GB or writing outputs if the draft input is absent/bad.
              python ${./nix/verify-mtp-source.py} "$STRATA_QWEN38_MTP_SOURCE" ${./nix/qwen38-mtp-manifest.json}
              model=$(realpath -- "$STRATA_MODEL")
              suffix=-00001-of-00002.gguf
              if [[ "$model" != *"$suffix" ]]; then
                echo "Expected the first IQ3_XXS shard" >&2
                exit 2
              fi
              shard2="''${model%"$suffix"}-00002-of-00002.gguf"
              test -f "$shard2"
              check_hash() {
                local actual
                actual=$(sha256sum -- "$1")
                if [[ "''${actual%% *}" != "$2" ]]; then
                  echo "Model SHA-256 mismatch: $1" >&2
                  exit 1
                fi
              }
              check_hash "$model" 219ea929900dfa9ef091f3aa473fdba6874b65fcb36526d7d851ac9e95856d15
              check_hash "$shard2" 316b46f3a2dbd68c900f43136ab9449f9dcc3725dfd8c794847c204bc161e113
              export STRATA_GGUF_PY=${llamaSource}/gguf-py
              python ${packSource}/tools/iq_pack.py --gguf "$model" --out "$STRATA_PREPARED_DIR/pack" \
                --expert-profile ${./data/expert-profile.bin}
              python ${packSource}/tools/mtp_pack.py --src "$STRATA_QWEN38_MTP_SOURCE" \
                --experts q2_0 --out "$STRATA_PREPARED_DIR/mtp-q2_0.gguf"
              python ${packSource}/tools/mtp_rt.py --gguf "$STRATA_PREPARED_DIR/mtp-q2_0.gguf" \
                --out "$STRATA_PREPARED_DIR/mtp"
              cp ${./data/draft_vocab.bin} "$STRATA_PREPARED_DIR/mtp/draft_vocab.bin"
            '';
          };
          serveQwen38 = pkgs.writeShellApplication {
            name = "strata-qwen38";
            extraShellCheckFlags = [ "-x" ];
            runtimeInputs = [ pkgs.systemd ];
            text = ''
              source ${launcherCommon}
              load_qwen38_env
              if [ "$#" -ge 2 ] && [[ "$1" != -* ]]; then
                STRATA_MODEL=$1
                STRATA_PREPARED_DIR=$2
                shift 2
              fi
              if [ -z "$STRATA_MODEL" ]; then
                echo "Set STRATA_QWEN38_MODEL in .env or pass SHARD1.gguf PREPARED_DIR" >&2
                exit 2
              fi
              strata_configure_args "$@"
              # Use a PTY in terminals so Ctrl-C reaches the service; otherwise
              # retain pipe mode for redirected/noninteractive invocations.
              exec systemd-run --user --wait --pty --pipe --collect --quiet \
                --unit=strata-qwen38 --working-directory="$PWD" \
                -p "MemoryMax=''${STRATA_QWEN38_MEMORY_MAX:-48G}" -p MemorySwapMax=0 \
                ${strata}/bin/unbiased-strata --model "$STRATA_MODEL" \
                --pack "$STRATA_PREPARED_DIR/pack" --mtp "$STRATA_PREPARED_DIR/mtp" \
                "''${strata_server_args[@]}" -- \
                --resident-experts --ple-io mmap \
                --vram-reserve-mib "''${STRATA_QWEN38_VRAM_RESERVE_MIB:-4096}" \
                "''${strata_engine_args[@]}"
            '';
          };
          gpuCheck = pkgs.writeShellApplication {
            name = "strata-check-gpu";
            runtimeInputs = [ strata ];
            text = ''
              strata-device
              for pair in q4_K/q5_K q4_K/q6_K q5_K/q6_K; do
                native_expert_parity --geom 2048x512 --synthetic "$pair"
              done
            '';
          };
        in
        {
          packages = {
            default = strata;
            inherit strata;
            prepare-qwen36 = prepareLocal;
            qwen36 = serveLocal;
            qwen36-aio = aioLauncher;
            prepare-qwen38 = prepareQwen38;
            qwen38 = serveQwen38;
            qwen38-aio = qwen38AioLauncher;
          };
          apps.prepare-qwen38 = {
            type = "app";
            program = "${prepareQwen38}/bin/strata-prepare-qwen38";
          };
          apps.qwen38-aio = {
            type = "app";
            program = "${qwen38AioLauncher}/bin/strata-qwen38-aio";
          };
          apps.qwen38 = {
            type = "app";
            program = "${serveQwen38}/bin/strata-qwen38";
          };
          apps.default = {
            type = "app";
            program = "${strata}/bin/unbiased-strata";
          };
          apps.qwen36 = {
            type = "app";
            program = "${serveLocal}/bin/strata-qwen36";
          };
          apps.prepare-qwen36 = {
            type = "app";
            program = "${prepareLocal}/bin/strata-prepare-qwen36";
          };
          apps.qwen36-aio = {
            type = "app";
            program = "${aioLauncher}/bin/strata-qwen36-aio";
          };
          legacyPackages = {
            inherit model;
            model-pack = modelPack;
            qwen36-aio = serveAio;
            qwen38-model = qwen38Model;
            qwen38-mtp-source = qwen38MtpSource;
            qwen38-model-pack = qwen38ModelPack;
            qwen38-aio = serveQwen38Aio;
          };
          apps.check-gpu = {
            type = "app";
            program = "${gpuCheck}/bin/strata-check-gpu";
          };
          checks.package = strata;
          checks.mtp-fetch =
            pkgs.runCommand "strata-pinned-mtp-fetch-tests"
              {
                nativeBuildInputs = [ python ];
              }
              ''
                python ${./nix/verify-mtp-source-test.py} ${./nix/verify-mtp-source.py} \
                  ${./nix/qwen38-mtp-manifest.json} ${packSource}/tools
                python ${./nix/mtp-fetch-pinned-test.py} ${./nix/mtp-fetch-pinned.py}
                # The upstream Setup test imports the installer removed by this fork.
                PYTHONPATH=${packSource}/tools python -m unittest test_mtp_fetch.Ranges test_mtp_fetch.Pinned
                  touch "$out"
              '';
          checks.local-preparation =
            pkgs.runCommand "strata-local-preparation-tests"
              {
                nativeBuildInputs = [
                  pkgs.bash
                  pkgs.gnugrep
                ];
              }
              ''
                bash ${./nix/local-preparation-test.sh} \
                  ${prepareLocal}/bin/strata-prepare-qwen36 ${prepareQwen38}/bin/strata-prepare-qwen38
                touch "$out"
              '';
          checks.launcher-config =
            pkgs.runCommand "strata-launcher-config-tests"
              {
                nativeBuildInputs = [ pkgs.bash ];
              }
              ''
                bash ${./nix/launcher-common-test.sh} ${launcherCommon}
                touch "$out"
              '';
          checks.frontend = pkgs.stdenv.mkDerivation {
            name = "strata-frontend-tests";
            src = pkgs.lib.fileset.toSource {
              root = ./.;
              fileset = pkgs.lib.fileset.unions [
                ./Makefile
                ./frontend
              ];
            };
            buildPhase = "make test-frontend";
            installPhase = "touch $out";
          };
          devShells.default = pkgs.mkShell {
            packages = [
              pkgs.cmake
              pkgs.ninja
              python
              rocm.clr
              rocm.hipblas
              rocm.rocblas
            ];
            STRATA_GGUF_PY = "${llamaSource}/gguf-py";
          };
          formatter = pkgs.nixfmt;
        };
    };
}
