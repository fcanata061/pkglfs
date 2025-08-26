#!/bin/bash
WORK=${WORK:-"$HOME/work"}
SOURCES=${SOURCES:-"$HOME/sources"}
PATCH=${PATCH:-"$HOME/patch"}
PKG=${PKG:-"$WORK/pkg"}         # diretório temporário de instalação
PREFIX=${PREFIX:-"/usr/local"}
REPO=${REPO:-"$HOME/recipes"}   # diretório raiz das receitas

ACTION="$1"
TARGET="$2"

[ -z "$ACTION" ] || [ -z "$TARGET" ] && {
    echo "Uso: $0 {install|remove} <receita|subdiretorio>"
    exit 1
}
# Função para processar uma receita individual
process_recipe() {
    local recipe="$1"
    [ -f "$recipe" ] || { echo "[ERRO] Receita não encontrada: $recipe"; return 1; }
    # Carregar variáveis e funções da receita
    source "$recipe"
    echo "[INFO] Processando $NAME $VERSION"
    # Função interna: download e extrair
    download_and_extract() {
        mkdir -p "$WORK" "$SOURCES"
        cd "$SOURCES" || exit 1
        local file=$(basename "$URL")
        [ -f "$file" ] || curl -L "$URL" -o "$file" || exit 1

        cd "$WORK" || exit 1
        case "$file" in
            *.tar.gz|*.tgz) tar -xvzf "$SOURCES/$file" ;;
            *.tar.bz2)      tar -xvjf "$SOURCES/$file" ;;
            *.tar.xz)       tar -xvJf "$SOURCES/$file" ;;
            *.tar)          tar -xvf "$SOURCES/$file" ;;
            *.zip)          unzip -o "$SOURCES/$file" ;;
            *) echo "[ERRO] Formato não suportado: $file"; return 1 ;;
        esac

        SRC_DIR=$(tar -tf "$SOURCES/$file" | head -1 | cut -f1 -d"/")
        cd "$SRC_DIR" || exit 1
        # Aplicar patches se existirem
        if [ -d "$PATCH/$NAME" ]; then
            for p in "$PATCH/$NAME"/*.patch; do
                [ -f "$p" ] || continue
                echo "[INFO] Aplicando patch $p..."
                patch -p1 < "$p"
            done
        fi
    }

    PKGDIR="$PKG/$NAME-$VERSION"
    MANIFEST="$WORK/$NAME-$VERSION.list"

    case "$ACTION" in
        install)
            echo "[INFO] Instalando $NAME $VERSION ..."
            download_and_extract
            rm -rf "$PKGDIR"
            mkdir -p "$PKGDIR"
            # Build dentro do fakeroot usando DESTDIR
            fakeroot bash -c "
                set -e
                export DESTDIR=\"$PKGDIR\"
                build
            "
            # gerar manifesto
            ( cd "$PKGDIR" && find . -type f -o -type d | sort ) > "$MANIFEST"
            # criar tar.gz do pacote
            PKG_ARCHIVE="$WORK/$NAME-$VERSION.tar.gz"
            tar -czf "$PKG_ARCHIVE" -C "$PKGDIR" .

            echo "[SUCESSO] $NAME instalado em fakeroot ($PKGDIR)"
            echo "           Manifesto salvo em $MANIFEST"
            echo "           Pacote tar.gz criado em $PKG_ARCHIVE"
            ;;
        remove)
            echo "[INFO] Removendo $NAME ..."
            if [ -f "$MANIFEST" ]; then
                tac "$MANIFEST" | while read -r f; do
                    target="/${f#./}"
                    [ -f "$target" ] && sudo rm -f "$target"
                    [ -d "$target" ] && sudo rmdir --ignore-fail-on-non-empty "$target" 2>/dev/null || true
                done
            else
                echo "[WARN] Manifesto não encontrado, removendo apenas via receita"
            fi
            # pós-remoção da receita
            remove || true
            echo "[SUCESSO] $NAME removido."
            ;;
    esac
}
# Processar diretório ou receita individual
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
