# The Nixpkgs CC is not directly usable, since it doesn't know where
# the C library and standard header files are. Therefore the compiler
# produced by that package cannot be installed directly in a user
# environment and used from the command line. So we use a wrapper
# script that sets up the right environment variables so that the
# compiler and the linker just "work".

{ name ? ""
, lib
, stdenvNoCC
, bintools ? null, libc ? null, coreutils ? null, shell ? stdenvNoCC.shell, gnugrep ? null
, netbsd ? null, netbsdCross ? null
, sharedLibraryLoader ?
  if libc == null then
    null
  else if stdenvNoCC.targetPlatform.isNetBSD then
    if !(targetPackages ? netbsdCross) then
      netbsd.ld_elf_so
    else if libc != targetPackages.netbsdCross.headers then
      targetPackages.netbsdCross.ld_elf_so
    else
      null
  else
    lib.getLib libc
, nativeTools, noLibc ? false, nativeLibc, nativePrefix ? ""
, propagateDoc ? bintools != null && bintools ? man
, extraPackages ? [], extraBuildCommands ? ""
, buildPackages ? {}
, targetPackages ? {}
, useMacosReexportHack ? false

# Darwin code signing support utilities
, postLinkSignHook ? null, signingUtils ? null
}:

with lib;

assert nativeTools -> !propagateDoc && nativePrefix != "";
assert !nativeTools ->
  bintools != null && coreutils != null && gnugrep != null;
assert !(nativeLibc && noLibc);
assert (noLibc || nativeLibc) == (libc == null);

let
  stdenv = stdenvNoCC;
  inherit (stdenv) hostPlatform targetPlatform;

  # Prefix for binaries. Customarily ends with a dash separator.
  #
  # TODO(@Ericson2314) Make unconditional, or optional but always true by
  # default.
  targetPrefix = lib.optionalString (targetPlatform != hostPlatform)
                                        (targetPlatform.config + "-");

  bintoolsVersion = lib.getVersion bintools;
  bintoolsName = lib.removePrefix targetPrefix (lib.getName bintools);

  libc_bin = if libc == null then null else getBin libc;
  libc_dev = if libc == null then null else getDev libc;
  libc_lib = if libc == null then null else getLib libc;
  bintools_bin = if nativeTools then "" else getBin bintools;
  # The wrapper scripts use 'cat' and 'grep', so we may need coreutils.
  coreutils_bin = if nativeTools then "" else getBin coreutils;

  # See description in cc-wrapper.
  suffixSalt = replaceStrings ["-" "."] ["_" "_"] targetPlatform.config;

  # The dynamic linker has different names on different platforms. This is a
  # shell glob that ought to match it.
  dynamicLinker =
    /**/ if sharedLibraryLoader == null then null
    else if targetPlatform.libc == "musl"             then "${sharedLibraryLoader}/lib/ld-musl-*"
    else if (targetPlatform.libc == "bionic" && targetPlatform.is32bit) then "/system/bin/linker"
    else if (targetPlatform.libc == "bionic" && targetPlatform.is64bit) then "/system/bin/linker64"
    else if targetPlatform.libc == "nblibc"           then "${sharedLibraryLoader}/libexec/ld.elf_so"
    else if targetPlatform.system == "i686-linux"     then "${sharedLibraryLoader}/lib/ld-linux.so.2"
    else if targetPlatform.system == "x86_64-linux"   then "${sharedLibraryLoader}/lib/ld-linux-x86-64.so.2"
    else if targetPlatform.system == "powerpc64le-linux" then "${sharedLibraryLoader}/lib/ld64.so.2"
    # ARM with a wildcard, which can be "" or "-armhf".
    else if (with targetPlatform; isAarch32 && isLinux)   then "${sharedLibraryLoader}/lib/ld-linux*.so.3"
    else if targetPlatform.system == "aarch64-linux"  then "${sharedLibraryLoader}/lib/ld-linux-aarch64.so.1"
    else if targetPlatform.system == "powerpc-linux"  then "${sharedLibraryLoader}/lib/ld.so.1"
    else if targetPlatform.isMips                     then "${sharedLibraryLoader}/lib/ld.so.1"
    else if targetPlatform.isDarwin                   then "/usr/lib/dyld"
    else if targetPlatform.isFreeBSD                  then "/libexec/ld-elf.so.1"
    else if lib.hasSuffix "pc-gnu" targetPlatform.config then "ld.so.1"
    else null;

  expand-response-params =
    if buildPackages ? stdenv && buildPackages.stdenv.hasCC && buildPackages.stdenv.cc != "/dev/null"
    then import ../expand-response-params { inherit (buildPackages) stdenv; }
    else "";

in

stdenv.mkDerivation {
  pname = targetPrefix
    + (if name != "" then name else "${bintoolsName}-wrapper");
  version = if bintools == null then null else bintoolsVersion;

  preferLocalBuild = true;

  inherit bintools_bin libc_bin libc_dev libc_lib coreutils_bin;
  shell = getBin shell + shell.shellPath or "";
  gnugrep_bin = if nativeTools then "" else gnugrep;

  inherit targetPrefix suffixSalt;

  outputs = [ "out" ] ++ optionals propagateDoc ([ "man" ] ++ optional (bintools ? info) "info");

  passthru = {
    inherit bintools libc nativeTools nativeLibc nativePrefix;

    emacsBufferSetup = pkgs: ''
      ; We should handle propagation here too
      (mapc
        (lambda (arg)
          (when (file-directory-p (concat arg "/lib"))
            (setenv "NIX_LDFLAGS_${suffixSalt}" (concat (getenv "NIX_LDFLAGS_${suffixSalt}") " -L" arg "/lib")))
          (when (file-directory-p (concat arg "/lib64"))
            (setenv "NIX_LDFLAGS_${suffixSalt}" (concat (getenv "NIX_LDFLAGS_${suffixSalt}") " -L" arg "/lib64"))))
        '(${concatStringsSep " " (map (pkg: "\"${pkg}\"") pkgs)}))
    '';
  };

  dontBuild = true;
  dontConfigure = true;

  unpackPhase = ''
    src=$PWD
  '';

  installPhase =
    ''
      mkdir -p $out/bin $out/nix-support

      wrap() {
        local dst="$1"
        local wrapper="$2"
        export prog="$3"
        substituteAll "$wrapper" "$out/bin/$dst"
        chmod +x "$out/bin/$dst"
      }
    ''

    + (if nativeTools then ''
      echo ${nativePrefix} > $out/nix-support/orig-bintools

      ldPath="${nativePrefix}/bin"
    '' else ''
      echo $bintools_bin > $out/nix-support/orig-bintools

      ldPath="${bintools_bin}/bin"
    ''

    # Solaris needs an additional ld wrapper.
    + optionalString (targetPlatform.isSunOS && nativePrefix != "") ''
      ldPath="${nativePrefix}/bin"
      exec="$ldPath/${targetPrefix}ld"
      wrap ld-solaris ${./ld-solaris-wrapper.sh}
    '')

    # Create a symlink to as (the assembler).
    + ''
      if [ -e $ldPath/${targetPrefix}as ]; then
        ln -s $ldPath/${targetPrefix}as $out/bin/${targetPrefix}as
      fi

    '' + (if !useMacosReexportHack then ''
      wrap ${targetPrefix}ld ${./ld-wrapper.sh} ''${ld:-$ldPath/${targetPrefix}ld}
    '' else ''
      ldInner="${targetPrefix}ld-reexport-delegate"
      wrap "$ldInner" ${./macos-sierra-reexport-hack.bash} ''${ld:-$ldPath/${targetPrefix}ld}
      wrap "${targetPrefix}ld" ${./ld-wrapper.sh} "$out/bin/$ldInner"
      unset ldInner
    '') + ''

      for variant in ld.gold ld.bfd ld.lld; do
        local underlying=$ldPath/${targetPrefix}$variant
        [[ -e "$underlying" ]] || continue
        wrap ${targetPrefix}$variant ${./ld-wrapper.sh} $underlying
      done
    '';

  emulation = let
    fmt =
      /**/ if targetPlatform.isDarwin  then "mach-o"
      else if targetPlatform.isWindows then "pe"
      else "elf" + toString targetPlatform.parsed.cpu.bits;
    endianPrefix = if targetPlatform.isBigEndian then "big" else "little";
    sep = optionalString (!targetPlatform.isMips && !targetPlatform.isPower && !targetPlatform.isRiscV) "-";
    arch =
      /**/ if targetPlatform.isAarch64 then endianPrefix + "aarch64"
      else if targetPlatform.isAarch32     then endianPrefix + "arm"
      else if targetPlatform.isx86_64  then "x86-64"
      else if targetPlatform.isx86_32  then "i386"
      else if targetPlatform.isMips    then {
          mips     = "btsmipn32"; # n32 variant
          mipsel   = "ltsmipn32"; # n32 variant
          mips64   = "btsmip";
          mips64el = "ltsmip";
        }.${targetPlatform.parsed.cpu.name}
      else if targetPlatform.isMmix then "mmix"
      else if targetPlatform.isPower then if targetPlatform.isBigEndian then "ppc" else "lppc"
      else if targetPlatform.isSparc then "sparc"
      else if targetPlatform.isMsp430 then "msp430"
      else if targetPlatform.isAvr then "avr"
      else if targetPlatform.isAlpha then "alpha"
      else if targetPlatform.isVc4 then "vc4"
      else if targetPlatform.isOr1k then "or1k"
      else if targetPlatform.isM68k then "m68k"
      else if targetPlatform.isS390 then "s390"
      else if targetPlatform.isRiscV then "lriscv"
      else throw "unknown emulation for platform: ${targetPlatform.config}";
    in if targetPlatform.useLLVM or false then ""
       else targetPlatform.bfdEmulation or (fmt + sep + arch);

  strictDeps = true;
  depsTargetTargetPropagated = extraPackages;

  wrapperName = "BINTOOLS_WRAPPER";

  setupHooks = [
    ../setup-hooks/role.bash
    ./setup-hook.sh
  ];

  postFixup =
    ##
    ## General libc support
    ##
    optionalString (libc != null) (''
      touch "$out/nix-support/libc-ldflags"
      echo "-L${libc_lib}${libc.libdir or "/lib"}" >> $out/nix-support/libc-ldflags

      echo "${libc_lib}" > $out/nix-support/orig-libc
      echo "${libc_dev}" > $out/nix-support/orig-libc-dev
    ''

    ##
    ## Dynamic linker support
    ##
    + optionalString (sharedLibraryLoader != null) ''
      if [[ -z ''${dynamicLinker+x} ]]; then
        echo "Don't know the name of the dynamic linker for platform '${targetPlatform.config}', so guessing instead." >&2
        local dynamicLinker="${sharedLibraryLoader}/lib/ld*.so.?"
      fi
    ''

    # Expand globs to fill array of options
    + ''
      dynamicLinker=($dynamicLinker)

      case ''${#dynamicLinker[@]} in
        0) echo "No dynamic linker found for platform '${targetPlatform.config}'." >&2;;
        1) echo "Using dynamic linker: '$dynamicLinker'" >&2;;
        *) echo "Multiple dynamic linkers found for platform '${targetPlatform.config}'." >&2;;
      esac

      if [ -n "''${dynamicLinker-}" ]; then
        echo $dynamicLinker > $out/nix-support/dynamic-linker

        ${if targetPlatform.isDarwin then ''
          printf "export LD_DYLD_PATH=%q\n" "$dynamicLinker" >> $out/nix-support/setup-hook
        '' else lib.optionalString (sharedLibraryLoader != null) ''
          if [ -e ${sharedLibraryLoader}/lib/32/ld-linux.so.2 ]; then
            echo ${sharedLibraryLoader}/lib/32/ld-linux.so.2 > $out/nix-support/dynamic-linker-m32
          fi
          touch $out/nix-support/ld-set-dynamic-linker
        ''}
      fi
    '')

    ##
    ## User env support
    ##

    # Propagate the underling unwrapped bintools so that if you
    # install the wrapper, you get tools like objdump (same for any
    # binaries of libc).
    + optionalString (!nativeTools) ''
      printWords ${bintools_bin} ${if libc == null then "" else libc_bin} > $out/nix-support/propagated-user-env-packages
    ''

    ##
    ## Man page and info support
    ##
    + optionalString propagateDoc (''
      ln -s ${bintools.man} $man
    '' + optionalString (bintools ? info) ''
      ln -s ${bintools.info} $info
    '')

    ##
    ## Hardening support
    ##

    # some linkers on some platforms don't support specific -z flags
    + ''
      export hardening_unsupported_flags=""
      if [[ "$($ldPath/${targetPrefix}ld -z now 2>&1 || true)" =~ un(recognized|known)\ option ]]; then
        hardening_unsupported_flags+=" bindnow"
      fi
      if [[ "$($ldPath/${targetPrefix}ld -z relro 2>&1 || true)" =~ un(recognized|known)\ option ]]; then
        hardening_unsupported_flags+=" relro"
      fi
    ''

    + optionalString hostPlatform.isCygwin ''
      hardening_unsupported_flags+=" pic"
    ''

    + optionalString targetPlatform.isAvr ''
      hardening_unsupported_flags+=" relro bindnow"
    ''

    + optionalString (libc != null && targetPlatform.isAvr) ''
      for isa in avr5 avr3 avr4 avr6 avr25 avr31 avr35 avr51 avrxmega2 avrxmega4 avrxmega5 avrxmega6 avrxmega7 tiny-stack; do
        echo "-L${getLib libc}/avr/lib/$isa" >> $out/nix-support/libc-cflags
      done
    ''

    + optionalString stdenv.targetPlatform.isDarwin ''
      echo "-arch ${targetPlatform.darwinArch}" >> $out/nix-support/libc-ldflags
    ''

    ###
    ### Remove LC_UUID
    ###
    + optionalString (stdenv.targetPlatform.isDarwin && !(bintools.isGNU or false)) ''
      echo "-no_uuid" >> $out/nix-support/libc-ldflags-before
    ''

    + ''
      for flags in "$out/nix-support"/*flags*; do
        substituteInPlace "$flags" --replace $'\n' ' '
      done

      substituteAll ${./add-flags.sh} $out/nix-support/add-flags.sh
      substituteAll ${./add-hardening.sh} $out/nix-support/add-hardening.sh
      substituteAll ${../wrapper-common/utils.bash} $out/nix-support/utils.bash
    ''

    ###
    ### Ensure consistent LC_VERSION_MIN_MACOSX
    ###
    + optionalString stdenv.targetPlatform.isDarwin (
      let
        inherit (stdenv.targetPlatform)
          darwinPlatform darwinSdkVersion
          darwinMinVersion darwinMinVersionVariable;
      in ''
        export darwinPlatform=${darwinPlatform}
        export darwinMinVersion=${darwinMinVersion}
        export darwinSdkVersion=${darwinSdkVersion}
        export darwinMinVersionVariable=${darwinMinVersionVariable}
        substituteAll ${./add-darwin-ldflags-before.sh} $out/nix-support/add-local-ldflags-before.sh
      ''
    )

    ##
    ## Code signing on Apple Silicon
    ##
    + optionalString (targetPlatform.isDarwin && targetPlatform.isAarch64) ''
      echo 'source ${postLinkSignHook}' >> $out/nix-support/post-link-hook

      export signingUtils=${signingUtils}

      wrap \
        ${targetPrefix}install_name_tool \
        ${./darwin-install_name_tool-wrapper.sh} \
        "${bintools_bin}/bin/${targetPrefix}install_name_tool"

      wrap \
        ${targetPrefix}strip ${./darwin-strip-wrapper.sh} \
        "${bintools_bin}/bin/${targetPrefix}strip"
    ''

    ##
    ## Extra custom steps
    ##
    + extraBuildCommands;

  inherit dynamicLinker expand-response-params;

  # for substitution in utils.bash
  expandResponseParams = "${expand-response-params}/bin/expand-response-params";

  meta =
    let bintools_ = if bintools != null then bintools else {}; in
    (if bintools_ ? meta then removeAttrs bintools.meta ["priority"] else {}) //
    { description =
        lib.attrByPath ["meta" "description"] "System binary utilities" bintools_
        + " (wrapper script)";
      priority = 10;
  } // optionalAttrs useMacosReexportHack {
    platforms = lib.platforms.darwin;
  };
}
