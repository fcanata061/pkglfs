#!/bin/bash

WORK=${WORK:-"$HOME/work"}
SOURCES=${SOURCES:-"$HOME/sources"}
PATCH=${PATCH:-"$HOME/patch"}
PKG=${PKG:-"$WORK/pkg"}
PREFIX=${PREFIX:-"/usr/local"}
REPO=${REPO:-"$HOME/recipes"}
LOGS="$WORK/logs"

ACTION="$1"
TARGET="$2"

[ -z "$ACTION" ] || [ -z "$TARGET" ] && {
    echo "Uso: $0 {install|remove} <receita|subdiretorio>"
    exit 1
}

mkdir -p "$LOGS"

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
        if [ ! -f "$file" ]; then
            echo "[INFO] Baixando $URL ..." | tee -a "$log"
            curl -L "$URL" -o "$file" 2>&1 | tee -a "$log" || exit 1
        fi

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

    case "$ACTION" in
        install)
            echo "[INFO] Instalando $NAME $VERSION ..." | tee -a "$log"
            download_and_extract
            rm -rf "$PKGDIR"
            mkdir -p "$PKGDIR"

            echo "[INFO] Executando build no fakeroot ..." | tee -a "$log"
            fakeroot bash -c "
                set -e
                export DESTDIR=\"$PKGDIR\"
                build
            " 2>&1 | tee -a "$log"

            ( cd "$PKGDIR" && find . -type f -o -type d | sort ) > "$MANIFEST"
            echo "[INFO] Manifesto gerado em $MANIFEST" | tee -a "$log"

            PKG_ARCHIVE="$WORK/$NAME-$VERSION.tar.gz"
            tar -czf "$PKG_ARCHIVE" -C "$PKGDIR" . 2>&1 | tee -a "$log"
            echo "[SUCESSO] Pacote tar.gz criado em $PKG_ARCHIVE" | tee -a "$log"
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
# processar diretório ou receita individual
if [ -d "$TARGET" ]; then
    for recipe in "$TARGET"/*/build.sh; do
        [ -f "$recipe" ] || continue
        process_recipe "$recipe"
    done
elif [ -f "$TARGET" ]; then
    process_recipe "$TARGET"
else
    echo "[ERRO] Arquivo ou diretório não encontrado: $TARGET"
    exit 1
fi
