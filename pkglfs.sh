#!/bin/bash
# generic-builder.sh - versão avançada
# CLI para compilar, empacotar, remover e recompilar pacotes Linux
#

WORK=${WORK:-"$HOME/work"}
SOURCES=${SOURCES:-"$HOME/sources"}
PATCH=${PATCH:-"$HOME/patch"}
PKG=${PKG:-"$WORK/pkg"}
PREFIX=${PREFIX:-"/usr/local"}
REPO=${REPO:-"$HOME/recipes"}
LOGS="$WORK/logs"
PKGS_DIR="$WORK/pkgs"
PARALLEL=${PARALLEL:-1}  # número de builds paralelos

mkdir -p "$LOGS" "$PKGS_DIR" "$PKG"

# --- Processar receita individual ---
process_recipe() {
    local recipe="$1"
    local do_command="$2"
    [ -f "$recipe" ] || { echo "[ERRO] Receita não encontrada: $recipe"; return 1; }

    source "$recipe"
    local log="$LOGS/$NAME-$VERSION.log"
    echo "[INFO] Processando $NAME $VERSION ($do_command)" | tee -a "$log"

    download_and_extract() {
        mkdir -p "$WORK" "$SOURCES"
        cd "$SOURCES" || exit 1
        local file=$(basename "$URL")
        [ -f "$file" ] || curl -L "$URL" -o "$file" 2>&1 | tee -a "$log" || exit 1

        cd "$WORK" || exit 1
        case "$file" in
            *.tar.gz|*.tgz) tar -xvzf "$SOURCES/$file" 2>&1 | tee -a "$log" ;;
            *.tar.bz2)      tar -xvjf "$SOURCES/$file" 2>&1 | tee -a "$log" ;;
            *.tar.xz)       tar -xvJf "$SOURCES/$file" 2>&1 | tee -a "$log" ;;
            *.tar)          tar -xvf "$SOURCES/$file" 2>&1 | tee -a "$log" ;;
            *.zip)          unzip -o "$SOURCES/$file" 2>&1 | tee -a "$log" ;;
            *) echo "[ERRO] Formato não suportado: $file" | tee -a "$log"; return 1 ;;
        esac

        SRC_DIR=$(tar -tf "$SOURCES/$file" | head -1 | cut -f1 -d"/")
        cd "$SRC_DIR" || exit 1

        if [ -d "$PATCH/$NAME" ]; then
            for p in "$PATCH/$NAME"/*.patch; do
                [ -f "$p" ] || continue
                echo "[INFO] Aplicando patch $p..." | tee -a "$log"
                patch -p1 < "$p" 2>&1 | tee -a "$log"
            done
        fi
    }

    PKGDIR="$PKG/$NAME-$VERSION"
    MANIFEST="$WORK/$NAME-$VERSION.list"
    TAR="$PKGS_DIR/$NAME-$VERSION.tar.gz"

    case "$do_command" in
        install)
            echo "[INFO] Instalando $NAME $VERSION ..." | tee -a "$log"
            download_and_extract
            rm -rf "$PKGDIR"
            mkdir -p "$PKGDIR"

            fakeroot bash -c "
                set -e
                export DESTDIR=\"$PKGDIR\"
                build
            " 2>&1 | tee -a "$log"

            ( cd "$PKGDIR" && find . -type f -o -type d | sort ) > "$MANIFEST"
            tar -czf "$TAR" -C "$PKGDIR" . 2>&1 | tee -a "$log"
            ;;
        build-only)
            echo "[INFO] Build-only $NAME $VERSION ..." | tee -a "$log"
            download_and_extract
            rm -rf "$PKGDIR"
            mkdir -p "$PKGDIR"

            bash -c "
                set -e
                build
            " 2>&1 | tee -a "$log"
            ;;
        remove)
            echo "[INFO] Removendo $NAME ..." | tee -a "$log"
            if [ -f "$MANIFEST" ]; then
                tac "$MANIFEST" | while read -r f; do
                    target="/${f#./}"
                    [ -f "$target" ] && sudo rm -f "$target" 2>&1 | tee -a "$log"
                    [ -d "$target" ] && sudo rmdir --ignore-fail-on-non-empty "$target" 2>/dev/null || true
                done
            else
                echo "[WARN] Manifesto não encontrado, removendo apenas via receita" | tee -a "$log"
            fi
            remove || true
            ;;
    esac
}

process_directory() {
    local dir="$1"
    local cmd="$2"
    local recipes=()
    for recipe in "$dir"/*/build.sh; do
        [ -f "$recipe" ] || continue
        recipes+=("$recipe")
    done

    if [ "$PARALLEL" -gt 1 ]; then
        echo "[INFO] Executando $cmd em paralelo ($PARALLEL jobs)"
        printf "%s\n" "${recipes[@]}" | xargs -n1 -P"$PARALLEL" -I{} bash -c "process_recipe \"{}\" \"$cmd\""
    else
        for r in "${recipes[@]}"; do
            process_recipe "$r" "$cmd"
        done
    fi
}

build_all() {
    for category in base x11 extra desktop; do
        [ -d "$REPO/$category" ] || continue
        process_directory "$REPO/$category" "install"
    done
}

rebuild_system() {
    echo "[INFO] Rebuild incremental do sistema ..."
    for category in base x11 extra desktop; do
        [ -d "$REPO/$category" ] || continue
        for recipe in "$REPO/$category"/*/build.sh; do
            [ -f "$recipe" ] || continue
            source "$recipe"
            TAR="$PKGS_DIR/$NAME-$VERSION.tar.gz"
            SRC_FILE="$SOURCES/$(basename $URL)"
            PATCH_DIR="$PATCH/$NAME"
            BUILD_SCRIPT="$recipe"
            # Recompila se algum arquivo mudou ou tarball não existe
            if [ ! -f "$TAR" ] || [ "$SRC_FILE" -nt "$TAR" ] || [ "$BUILD_SCRIPT" -nt "$TAR" ] || [ "$(find "$PATCH_DIR" -type f 2>/dev/null)" -nt "$TAR" ]; then
                process_recipe "$recipe" "build-only"
            else
                echo "[INFO] $NAME-$VERSION está atualizado, pulando rebuild"
            fi
        done
    done
}

clean_pkgs() {
    echo "[INFO] Limpando diretórios temporários e tarballs ..."
    rm -rf "$PKG" "$PKGS_DIR"
    mkdir -p "$PKG" "$PKGS_DIR"
}

# --- CLI ---
COMMAND="$1"
TARGET="$2"

case "$COMMAND" in
    install|remove|build-only)
        [ -z "$TARGET" ] && { echo "Falta argumento <receita|subdiretorio>"; exit 1; }
        if [ -d "$TARGET" ]; then
            process_directory "$TARGET" "$COMMAND"
        elif [ -f "$TARGET" ]; then
            process_recipe "$TARGET" "$COMMAND"
        else
            echo "[ERRO] Arquivo ou diretório não encontrado: $TARGET"; exit 1
        fi
        ;;
    build-all)
        build_all
        ;;
    rebuild-system)
        rebuild_system
        ;;
    clean-pkgs)
        clean_pkgs
        ;;
    *)
        echo "Uso: $0 {install|remove|build-only|build-all|rebuild-system|clean-pkgs} <receita|subdiretorio>"
        exit 1
        ;;
esac
