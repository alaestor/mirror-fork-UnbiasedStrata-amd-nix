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
          serviceCommon = ./nix/service-launcher.sh;
          mkServiceLauncher =
            modelName: variant:
            pkgs.writeShellApplication {
              name = "strata-${variant}";
              runtimeInputs = [
                pkgs.nix
                pkgs.systemd
              ];
              extraShellCheckFlags = [ "-x" ];
              text = ''
                source ${serviceCommon}
                strata_service_dispatch strata-${modelName}.service \
                  ${if modelName == "qwen38" then "true" else "false"} \
                  ${inputs.self}#legacyPackages.${system}.${variant} "$@"
              '';
            };
          source = pkgs.lib.fileset.toSource {
            root = ./.;
            fileset = pkgs.lib.fileset.unions [
              ./CMakeLists.txt
              ./cmake
              ./src
              ./include
              ./frontend
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
            owner = "robertkarl";
            repo = "llama.cpp";
            rev = "385445fad49e42fa718b5e1f71668f35b7a08559";
            hash = "sha256-U9xYwlyzNACah+wOnTfmU20leV0lnsWZgejGoBluYOQ=";
          };
          strata = pkgs.stdenv.mkDerivation {
            pname = "unbiased-strata-hip";
            version = "0.1.45-poly.1";
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
              cmake --build . --target unbiased-strata strata strata-poly strata-device native_expert_parity --parallel "$jobs"
              runHook postBuild
            '';
            installPhase = ''
              runHook preInstall
              install -Dm755 unbiased-strata "$out/bin/unbiased-strata"
              install -Dm755 strata "$out/bin/strata"
              install -Dm755 strata-poly "$out/bin/strata-poly"
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
          qwen38Revision = "ed59f92082b1e93c0e96d60a8b11aab089b52f09";
          qwen36Projector = pkgs.fetchurl {
            name = "Qwen3.6-35B-A3B-vision-mmproj-BF16.gguf";
            url = "https://huggingface.co/unsloth/Qwen3.6-35B-A3B-MTP-GGUF/resolve/${modelRevision}/mmproj-BF16.gguf";
            sha256 = "da63cb47a76763c712393f8a017070188a304fa39f8aeea6edc629ed7b975cfa";
          };
          qwen38Projector = pkgs.fetchurl {
            name = "Qwen3.8-Flash-Next-vision-mmproj-BF16.gguf";
            url = "https://huggingface.co/ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF/resolve/${qwen38Revision}/mmproj-Qwen3.8-Flash-Next-BF16.gguf";
            sha256 = "b1a82259702816a5330d7bd7607cd9676b11780e79ff7348c21103ff3ce49bd0";
          };
          mkAioMm =
            name: program: projector:
            pkgs.writeShellApplication {
              inherit name;
              text = ''
                export STRATA_SERVICE_ROOT="''${STRATA_SERVICE_ROOT:-''${0%/bin/*}}"
                exec ${program} --mmproj ${pkgs.lib.escapeShellArg "${projector}"} "$@"
              '';
            };
          serveAioMm = mkAioMm "strata-qwen36-aio-mm" "${serveAio}/bin/strata-qwen36-aio" qwen36Projector;
          serveQwen38AioMm =
            mkAioMm "strata-qwen38-aio-mm" "${serveQwen38Aio}/bin/strata-qwen38-aio"
              qwen38Projector;
          mkMmLauncher = modelName: mkServiceLauncher modelName "${modelName}-aio-mm";
          aioMmLauncher = mkMmLauncher "qwen36";
          qwen38AioMmLauncher = mkMmLauncher "qwen38";
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
            rev = qwen38Revision;
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
                  --out "$out/pack"
                cp ${./data/expert-profile.bin} "$out/pack/expert-profile.bin"
                python ${packSource}/tools/mtp_pack.py --src ${qwen38MtpSource} \
                  --experts q2_0 --out mtp-q2_0.gguf
                python ${packSource}/tools/mtp_rt.py --gguf mtp-q2_0.gguf --out "$out/mtp"
                cp ${./data/draft_vocab.bin} "$out/mtp/draft_vocab.bin"
              '';
          serveQwen38Aio = pkgs.writeShellApplication {
            name = "strata-qwen38-aio";
            text = ''
              export STRATA_SERVICE_ROOT="''${STRATA_SERVICE_ROOT:-''${0%/bin/*}}"
              exec ${serveQwen38}/bin/strata-qwen38 \
                ${qwen38Model}/IQ3_XXS/${qwen38Shard1} ${qwen38ModelPack} "$@"
            '';
          };
          qwen38AioLauncher = mkServiceLauncher "qwen38" "qwen38-aio";
          qwen38Launcher = mkServiceLauncher "qwen38" "qwen38";
          localLauncher = mkServiceLauncher "qwen36" "qwen36";
          python = pkgs.python3.withPackages (ps: [
            ps.numpy
            ps.regex
            ps.pyyaml
            ps.tqdm
          ]);
          serveAio = pkgs.writeShellApplication {
            name = "strata-qwen36-aio";
            runtimeInputs = [
              pkgs.systemd
              pkgs.nix
            ];
            extraShellCheckFlags = [ "-x" ];
            text = ''
              export STRATA_SERVICE_ROOT="''${STRATA_SERVICE_ROOT:-''${0%/bin/*}}"
              source ${launcherCommon}
              source ${serviceCommon}
              load_strata_env
              strata_configure_args "$@"
              strata_service_or_exec strata-qwen36.service ${strata}/bin/unbiased-strata \
                --engine strata-poly --model ${model}/${modelFile} \
                "''${strata_server_args[@]}" -- --model ${model}/${modelFile} "''${strata_engine_args[@]}"
            '';
          };
          # Defer engine/model evaluation until serving, including for controls.
          aioLauncher = mkServiceLauncher "qwen36" "qwen36-aio";
          serveLocal = pkgs.writeShellApplication {
            name = "strata-qwen36";
            runtimeInputs = [
              pkgs.systemd
              pkgs.nix
            ];
            extraShellCheckFlags = [ "-x" ];
            text = ''
              export STRATA_SERVICE_ROOT="''${STRATA_SERVICE_ROOT:-''${0%/bin/*}}"
              source ${launcherCommon}
              source ${serviceCommon}
              load_strata_env
              if [ "$#" -ge 1 ] && [[ "$1" != -* ]]; then
                STRATA_MODEL=$1
                shift
              fi
              if [ -z "$STRATA_MODEL" ]; then
                echo "Set STRATA_MODEL in .env or pass MODEL.gguf" >&2
                exit 2
              fi
              strata_configure_args "$@"
              strata_service_or_exec strata-qwen36.service ${strata}/bin/unbiased-strata --engine strata-poly --model "$STRATA_MODEL" \
                "''${strata_server_args[@]}" -- --model "$STRATA_MODEL" "''${strata_engine_args[@]}"
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
              # Fail before writing outputs if the draft input is absent/bad.
              python ${./nix/verify-mtp-source.py} "$STRATA_QWEN38_MTP_SOURCE" ${./nix/qwen38-mtp-manifest.json}
              model=$(realpath -- "$STRATA_MODEL")
              suffix=-00001-of-00002.gguf
              if [[ "$model" != *"$suffix" ]]; then
                echo "Expected the first IQ3_XXS shard" >&2
                exit 2
              fi
              shard2="''${model%"$suffix"}-00002-of-00002.gguf"
              test -f "$model"
              test -f "$shard2"
              export STRATA_GGUF_PY=${llamaSource}/gguf-py
              python ${packSource}/tools/iq_pack.py --gguf "$model" --out "$STRATA_PREPARED_DIR/pack"
              cp ${./data/expert-profile.bin} "$STRATA_PREPARED_DIR/pack/expert-profile.bin"
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
            runtimeInputs = [
              pkgs.systemd
              pkgs.nix
            ];
            text = ''
              export STRATA_SERVICE_ROOT="''${STRATA_SERVICE_ROOT:-''${0%/bin/*}}"
              source ${launcherCommon}
              source ${serviceCommon}
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
              strata_service_run strata-qwen38.service \
                -p "MemoryMax=''${STRATA_QWEN38_MEMORY_MAX:-48G}" -p MemorySwapMax=0 \
                ${pkgs.bash}/bin/bash ${./nix/memory-preflight.sh} \
                ${strata}/bin/unbiased-strata --engine strata --model "$STRATA_MODEL" \
                "''${strata_server_args[@]}" -- \
                --native "$STRATA_MODEL" --pack "$STRATA_PREPARED_DIR/pack" --mtp "$STRATA_PREPARED_DIR/mtp" \
                --expert-profile "$STRATA_PREPARED_DIR/pack/expert-profile.bin" --expert-cache auto --prefill auto --spec 4 \
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
              for pair in q4_K/q5_1 q5_K/q5_1 q6_K/q5_1; do
                native_expert_parity --synthetic "$pair"
              done
            '';
          };
        in
        {
          packages = {
            default = strata;
            inherit strata;
            qwen36 = localLauncher;
            qwen36-aio = aioLauncher;
            qwen36-aio-mm = aioMmLauncher;
            prepare-qwen38 = prepareQwen38;
            qwen38 = qwen38Launcher;
            qwen38-aio = qwen38AioLauncher;
            qwen38-aio-mm = qwen38AioMmLauncher;
          };
          apps.qwen36-aio-mm = {
            type = "app";
            program = "${aioMmLauncher}/bin/strata-qwen36-aio-mm";
          };
          apps.qwen38-aio-mm = {
            type = "app";
            program = "${qwen38AioMmLauncher}/bin/strata-qwen38-aio-mm";
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
            program = "${qwen38Launcher}/bin/strata-qwen38";
          };
          apps.default = {
            type = "app";
            program = "${strata}/bin/unbiased-strata";
          };
          apps.qwen36 = {
            type = "app";
            program = "${localLauncher}/bin/strata-qwen36";
          };
          apps.qwen36-aio = {
            type = "app";
            program = "${aioLauncher}/bin/strata-qwen36-aio";
          };
          legacyPackages = {
            inherit model;
            qwen36 = serveLocal;
            qwen38 = serveQwen38;
            qwen36-aio = serveAio;
            qwen36-mmproj = qwen36Projector;
            qwen36-aio-mm = serveAioMm;
            qwen38-model = qwen38Model;
            qwen38-mtp-source = qwen38MtpSource;
            qwen38-model-pack = qwen38ModelPack;
            qwen38-aio = serveQwen38Aio;
            qwen38-mmproj = qwen38Projector;
            qwen38-aio-mm = serveQwen38AioMm;
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
                STRATA_GGUF_PY = "${llamaSource}/gguf-py";
              }
              ''
                python ${./nix/verify-mtp-source-test.py} ${./nix/verify-mtp-source.py} \
                  ${./nix/qwen38-mtp-manifest.json} ${packSource}/tools
                python ${./nix/mtp-fetch-pinned-test.py} ${./nix/mtp-fetch-pinned.py}
                python -m unittest discover -s ${packSource}/tools -p test_iq_pack.py
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
                  ${prepareQwen38}/bin/strata-prepare-qwen38
                touch "$out"
              '';
          checks.launcher-config =
            pkgs.runCommand "strata-launcher-config-tests"
              {
                nativeBuildInputs = [ pkgs.bash ];
              }
              ''
                bash ${./nix/launcher-common-test.sh} ${launcherCommon}
                bash ${./nix/memory-preflight-test.sh} ${./nix/memory-preflight.sh}
                touch "$out"
              '';
          checks.service-launcher =
            pkgs.runCommand "strata-service-launcher-tests"
              {
                nativeBuildInputs = [
                  pkgs.bash
                  pkgs.gnugrep
                ];
              }
              ''
                bash ${./nix/service-launcher-test.sh} ${serviceCommon}
                touch "$out"
              '';
          checks.aio-mm =
            let
              mockServer =
                loader:
                pkgs.writeShellApplication {
                  name = "mock-aio-${loader}";
                  extraShellCheckFlags = [ "-x" ];
                  text = ''
                    source ${launcherCommon}
                    ${loader}
                    strata_configure_args "$@"
                    printf '%s\n' "''${strata_server_args[@]}" ENGINE "''${strata_engine_args[@]}"
                  '';
                };
              mock36 = mockServer "load_strata_env";
              mock38 = mockServer "load_qwen38_env";
              wrapper36 =
                mkAioMm "test-qwen36-aio-mm" "${mock36}/bin/mock-aio-load_strata_env"
                  "/models/qwen36 BF16.gguf";
              wrapper38 =
                mkAioMm "test-qwen38-aio-mm" "${mock38}/bin/mock-aio-load_qwen38_env"
                  "/models/qwen38 BF16.gguf";
            in
            pkgs.runCommand "strata-aio-mm-tests" { nativeBuildInputs = [ pkgs.bash ]; } ''
              bash ${./nix/aio-mm-test.sh} ${wrapper36}/bin/test-qwen36-aio-mm ${wrapper38}/bin/test-qwen38-aio-mm
              touch "$out"
            '';
          checks.frontend = pkgs.stdenv.mkDerivation {
            name = "strata-frontend-tests";
            src = source;
            nativeBuildInputs = [
              pkgs.cmake
              pkgs.ninja
              pkgs.python3
              pkgs.curl
            ];
            postUnpack = strata.postUnpack;
            postPatch = "patchShebangs frontend/tests";
            cmakeFlags = [
              "-DSTRATA_ENABLE_CUDA=OFF"
              "-DSTRATA_BUILD_TESTS=OFF"
            ];
            buildPhase = ''
              cmake --build . --target unbiased-strata engine_test literals_test picture_cache_test sampling_defaults_test --parallel 4
            '';
            doCheck = true;
            checkPhase = ''
              ./engine_test "$PWD/../frontend/tests/fake-engine.py"
              ./literals_test
              ./picture_cache_test
              ./sampling_defaults_test
              python3 ../frontend/tests/sampling-defaults-e2e.py "$PWD/unbiased-strata"
              bash ../frontend/tests/e2e.sh "$PWD/unbiased-strata"
            '';
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
