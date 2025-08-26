#!/bin/bash
#
# generic-builder.sh
#
# CLI para compilar, empacotar e remover pacotes
#

WORK=${WORK:-"$HOME/work"}
SOURCES=${SOURCES:-"$HOME/sources"}
PATCH=${PATCH:-"$HOME/patch"}
PKG=${PKG:-"$WORK/pkg"}
PREFIX=${PREFIX:-"/usr/local"}
REPO=${REPO:-"$HOME/recipes"}
LOGS="$WORK/logs"
PKGS_DIR="$WORK/pkgs"

mkdir -p "$LOGS" "$PKGS_DIR"

# --- Função principal para processar uma receita ---
process_recipe() {
    local recipe="$1"
    [ -f "$recipe" ] || { echo "[ERRO] Receita não encontrada: $recipe"; return 1; }

    source "$recipe"
    local log="$LOGS/$NAME-$VERSION.log"
    echo "[INFO] Processando $NAME $VERSION" | tee -a "$log"

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

    case "$COMMAND" in
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
            PKG_ARCHIVE="$PKGS_DIR/$NAME-$VERSION.tar.gz"
            tar -czf "$PKG_ARCHIVE" -C "$PKGDIR" . 2>&1 | tee -a "$log"

            echo "[SUCESSO] $NAME instalado em fakeroot ($PKGDIR)" | tee -a "$log"
            echo "[INFO] Manifesto salvo em $MANIFEST" | tee -a "$log"
            echo "[INFO] Pacote tar.gz criado em $PKG_ARCHIVE" | tee -a "$log"
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
            echo "[SUCESSO] $NAME removido." | tee -a "$log"
            ;;
    esac
}

# --- Função para processar diretório completo ---
process_directory() {
    local dir="$1"
    for recipe in "$dir"/*/build.sh; do
        [ -f "$recipe" ] || continue
        process_recipe "$recipe"
    done
}

# --- Função build-all ---
build_all() {
    for category in base x11 extra desktop; do
        dir="$REPO/$category"
        [ -d "$dir" ] || continue
        process_directory "$dir"
    done
}

# --- Função clean-pkgs ---
clean_pkgs() {
    echo "[INFO] Limpando diretórios temporários e tarballs ..."
    rm -rf "$PKG" "$PKGS_DIR"
    mkdir -p "$PKG" "$PKGS_DIR"
    echo "[SUCESSO] Diretórios limpos."
}

# --- Interpretar comando CLI ---
COMMAND="$1"
TARGET="$2"

case "$COMMAND" in
    install|remove)
        [ -z "$TARGET" ] && { echo "Falta argumento <receita|subdiretorio>"; exit 1; }
        if [ -d "$TARGET" ]; then
            process_directory "$TARGET"
        elif [ -f "$TARGET" ]; then
            process_recipe "$TARGET"
        else
            echo "[ERRO] Arquivo ou diretório não encontrado: $TARGET"; exit 1
        fi
        ;;
    build-all)
        build_all
        ;;
    clean-pkgs)
        clean_pkgs
        ;;
    *)
        echo "Uso: $0 {install|remove|build-all|clean-pkgs} <receita|subdiretorio>"
        exit 1
        ;;
esac
