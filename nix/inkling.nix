{
  perSystem =
    { config, pkgs, ... }:
    let
      pin = builtins.fromJSON (builtins.readFile ../packaging/inkling/source.json);
      rocm = pkgs.rocmPackages;
      engine = pkgs.stdenv.mkDerivation {
        pname = "strata-inkling-hip";
        inherit (pin) version;
        src = pkgs.fetchurl {
          name = "strata-${pin.version}-source.tar.gz";
          inherit (pin) url sha256;
        };
        cmakeDir = "../engine/src/inkling2";
        nativeBuildInputs = [
          pkgs.cmake
          pkgs.ninja
        ];
        buildInputs = [ rocm.clr ];
        cmakeFlags = [
          "-DSTRATA_ENABLE_HIP=ON"
          "-DSTRATA_HIP_ARCHS=gfx1100"
          "-DSTRATA_HIP_CXX=${rocm.clr.hipClangPath}/clang++"
          "-DSTRATA_HIP_RUNTIME_LIB=${rocm.clr}/lib/libamdhip64.so"
        ];
        buildPhase = ''
          runHook preBuild
          cmake --build . --target strata-inkling --parallel 4
          runHook postBuild
        '';
        installPhase = ''
          runHook preInstall
          cmake --install . --component inkling2
          install -Dm644 ../LICENSE "$out/share/licenses/strata-inkling/LICENSE"
          runHook postInstall
        '';
        doInstallCheck = true;
        installCheckPhase = ''
          "$out/bin/strata-inkling" --version | grep -Fx 'strata-inkling ${pin.version}'
        '';
        meta = {
          description = "Niko1221's standalone Strata Inkling 2 HIP engine for gfx1100";
          license = pkgs.lib.licenses.mit;
          mainProgram = "strata-inkling";
        };
      };
      # Reuse the existing front-end sources without compiling the Qwen HIP engines.
      frontend = config.packages.strata.overrideAttrs {
        pname = "unbiased-strata-frontend";
        buildInputs = [ ];
        cmakeFlags = [
          "-DSTRATA_ENABLE_HIP=OFF"
          "-DSTRATA_ENABLE_CUDA=OFF"
          "-DSTRATA_BUILD_TESTS=OFF"
          "-DSTRATA_PORTABLE=ON"
        ];
        buildPhase = ''
          runHook preBuild
          cmake --build . --target unbiased-strata --parallel 4
          runHook postBuild
        '';
        installPhase = ''
          runHook preInstall
          install -Dm755 unbiased-strata "$out/bin/unbiased-strata"
          runHook postInstall
        '';
      };
      launcher = pkgs.writeShellApplication {
        name = "inkling";
        text = ''
          inkling_frontend=${frontend}/bin/unbiased-strata
          inkling_engine=${engine}/bin/strata-inkling
          # shellcheck disable=SC1091
          source ${./launcher-common.sh}
          ${builtins.readFile ../packaging/inkling/launch.sh}
        '';
      };
    in
    {
      packages.strata-inkling-hip = engine;
      packages.inkling = launcher;
      apps.inkling = {
        type = "app";
        program = "${launcher}/bin/inkling";
      };
      checks.strata-inkling-hip = engine;
      checks.inkling-launcher = pkgs.runCommand "inkling-launcher-tests" { } ''
        bash ${../packaging/inkling/launch-test.sh} ${./launcher-common.sh} ${../packaging/inkling/launch.sh}
        touch "$out"
      '';
    };
}
