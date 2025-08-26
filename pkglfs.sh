#!/bin/bash
#
# generic-builder.sh
#
# Uso:
#   ./generic-builder.sh install ./recipes/hello/build.sh
#   ./generic-builder.sh remove  ./recipes/hello/build.sh
#

WORK=${WORK:-"$HOME/work"}
SOURCES=${SOURCES:-"$HOME/sources"}
PATCH=${PATCH:-"$HOME/patch"}
PKG=${PKG:-"$WORK/pkg"}   # Diretório de instalação temporário
PREFIX=${PREFIX:-"/usr/local"}

ACTION="$1"
RECIPE="$2"

[ -f "$RECIPE" ] || { echo "[ERRO] Receita não encontrada: $RECIPE"; exit 1; }

# Carregar receita (define NAME, VERSION, URL e funções build/remove)
source "$RECIPE"

download_and_extract() {
    mkdir -p "$WORK" "$SOURCES"

    cd "$SOURCES" || exit 1
    local file=$(basename "$URL")

    if [ ! -f "$file" ]; then
        echo "[INFO] Baixando $URL ..."
        curl -L "$URL" -o "$file" || exit 1
    fi

    cd "$WORK" || exit 1
    case "$file" in
        *.tar.gz|*.tgz) tar -xvzf "$SOURCES/$file" ;;
        *.tar.bz2)      tar -xvjf "$SOURCES/$file" ;;
        *.tar.xz)       tar -xvJf "$SOURCES/$file" ;;
        *.tar)          tar -xvf "$SOURCES/$file" ;;
        *.zip)          unzip -o "$SOURCES/$file" ;;
        *) echo "[ERRO] Formato não suportado: $file"; exit 1 ;;
    esac

    SRC_DIR=$(tar -tf "$SOURCES/$file" | head -1 | cut -f1 -d"/")
    cd "$SRC_DIR" || exit 1

    # Aplicar patches
    if [ -d "$PATCH/$NAME" ]; then
        for p in "$PATCH/$NAME"/*.patch; do
            [ -f "$p" ] || continue
            echo "[INFO] Aplicando patch $p..."
            patch -p1 < "$p"
        done
    fi
}

case "$ACTION" in
    install)
        echo "[INFO] Instalando $NAME $VERSION ..."
        download_and_extract

        PKGDIR="$PKG/$NAME-$VERSION"
        MANIFEST="$WORK/$NAME-$VERSION.list"

        rm -rf "$PKGDIR"
        mkdir -p "$PKGDIR"

        # Build dentro do fakeroot usando DESTDIR=$PKGDIR
        fakeroot bash -c "
            set -e
            export DESTDIR=\"$PKGDIR\"
            build
        "

        # gerar manifesto
        ( cd "$PKGDIR" && find . -type f -o -type d | sort ) > "$MANIFEST"

        # opcional: criar tar.gz do pacote
        PKG_ARCHIVE="$WORK/$NAME-$VERSION.tar.gz"
        tar -czf "$PKG_ARCHIVE" -C "$PKGDIR" .
        
        echo "[SUCESSO] $NAME instalado em fakeroot ($PKGDIR)"
        echo "           Manifesto salvo em $MANIFEST"
        echo "           Pacote tar.gz criado em $PKG_ARCHIVE"
        ;;
    remove)
        echo "[INFO] Removendo $NAME ..."
        PKGDIR="$PKG/$NAME-$VERSION"
        MANIFEST="$WORK/$NAME-$VERSION.list"

        if [ -f "$MANIFEST" ]; then
            tac "$MANIFEST" | while read -r f; do
                target="/${f#./}"
                if [ -f "$target" ]; then
                    sudo rm -f "$target"
                elif [ -d "$target" ]; then
                    sudo rmdir --ignore-fail-on-non-empty "$target" 2>/dev/null || true
                fi
            done
        else
            echo "[WARN] Manifesto não encontrado, removendo apenas via receita"
        fi

        # pós-remoção da receita
        remove || true

        echo "[SUCESSO] $NAME removido."
        ;;
    *)
        echo "Uso: $0 {install|remove} recipe.sh"
        exit 1
        ;;
esac
