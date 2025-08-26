#!/bin/bash
#
# pkg-cli.sh
# CLI completo: compilação, instalação, remoção, dependências, órfãos, logs, cores, spinner
#

WORK=${WORK:-"$HOME/work"}
SOURCES=${SOURCES:-"$HOME/sources"}
PATCH=${PATCH:-"$HOME/patch"}
PKG=${PKG:-"$WORK/pkg"}
PREFIX=${PREFIX:-"/usr/local"}
REPO=${REPO:-"$HOME/recipes"}
LOGS="$WORK/logs"
PKGS_DIR="$WORK/pkgs"
PARALLEL=${PARALLEL:-1}
INSTALLED_LIST="$HOME/.pkg_installed.list"

mkdir -p "$LOGS" "$PKGS_DIR" "$PKG"
touch "$INSTALLED_LIST"

# ===================== Cores =====================
RED="\033[0;31m"; GREEN="\033[0;32m"; YELLOW="\033[1;33m"; BLUE="\033[0;34m"; NC="\033[0m"
color_echo() { local c="$1"; shift; echo -e "${c}$*${NC}"; }

# ===================== Spinner =====================
spinner() { local pid=$!; local delay=0.1; local spinstr='|/-\'; while [ "$(ps a | awk '{print $1}' | grep $pid)" ]; do local temp=${spinstr#?}; printf " [%c]  " "$spinstr"; spinstr=$temp${spinstr%"$temp"}; sleep $delay; printf "\b\b\b\b\b\b"; done; printf "    \b\b\b\b"; }
run_with_spinner() { "$@" & spinner $!; }

# ===================== Dependências =====================
declare -A DEPENDENCIES
add_dependency() { local pkg="$1"; shift; DEPENDENCIES["$pkg"]="$*"; }
get_dependencies() { local pkg="$1"; echo "${DEPENDENCIES[$pkg]}"; }

is_installed() { grep -qxF "$1" "$INSTALLED_LIST"; }
add_installed_pkg() { local p="$1"; grep -qxF "$p" "$INSTALLED_LIST" || echo "$p" >> "$INSTALLED_LIST"; }
remove_installed_pkg() { grep -vxF "$1" "$INSTALLED_LIST" > "$INSTALLED_LIST.tmp"; mv "$INSTALLED_LIST.tmp" "$INSTALLED_LIST"; }
list_installed_pkgs() { cat "$INSTALLED_LIST"; }

install_dependencies() {
    local pkg="$1"
    local deps=$(get_dependencies "$pkg")
    for d in $deps; do
        if ! is_installed "$d"; then
            color_echo $BLUE "Instalando dependência $d..."
            run_with_spinner bash "$0" install "$REPO/base/$d/build.sh"
            add_installed_pkg "$d"
        fi
    done
}

remove_orphans() {
    local pkgs=($(list_installed_pkgs))
    local to_remove=()
    for pkg in "${pkgs[@]}"; do
        local dep_found=0
        for p in "${pkgs[@]}"; do
            [ "$p" == "$pkg" ] && continue
            deps=$(get_dependencies "$p")
            for d in $deps; do [ "$d" == "$pkg" ] && dep_found=1; done
        done
        [ $dep_found -eq 0 ] && to_remove+=("$pkg")
    done
    if [ ${#to_remove[@]} -eq 0 ]; then
        color_echo $GREEN "Nenhum pacote órfão encontrado"
    else
        color_echo $YELLOW "Pacotes órfãos: ${to_remove[*]}"
        for pkg in "${to_remove[@]}"; do
            bash "$0" remove "$REPO/base/$pkg/build.sh"
            remove_installed_pkg "$pkg"
        done
    fi
}

# ===================== Build e Install =====================
process_recipe() {
    local recipe="$1"
    local do_command="$2"
    [ -f "$recipe" ] || { color_echo $RED "Receita não encontrada: $recipe"; return 1; }

    source "$recipe"
    local log="$LOGS/$NAME-$VERSION.log"
    color_echo $BLUE "[INFO] Processando $NAME $VERSION ($do_command)" | tee -a "$log"

    download_and_extract() {
        mkdir -p "$WORK" "$SOURCES"; cd "$SOURCES" || exit 1
        local file=$(basename "$URL")
        [ -f "$file" ] || curl -L "$URL" -o "$file" 2>&1 | tee -a "$log" || exit 1
        cd "$WORK" || exit 1
        case "$file" in
            *.tar.gz|*.tgz) tar -xvzf "$SOURCES/$file" 2>&1 | tee -a "$log" ;;
            *.tar.bz2) tar -xvjf "$SOURCES/$file" 2>&1 | tee -a "$log" ;;
            *.tar.xz) tar -xvJf "$SOURCES/$file" 2>&1 | tee -a "$log" ;;
            *.tar) tar -xvf "$SOURCES/$file" 2>&1 | tee -a "$log" ;;
            *.zip) unzip -o "$SOURCES/$file" 2>&1 | tee -a "$log" ;;
            *) color_echo $RED "Formato não suportado: $file" | tee -a "$log"; return 1 ;;
        esac
        SRC_DIR=$(tar -tf "$SOURCES/$file" | head -1 | cut -f1 -d"/")
        cd "$SRC_DIR" || exit 1
        if [ -d "$PATCH/$NAME" ]; then
            for p in "$PATCH/$NAME"/*.patch; do
                [ -f "$p" ] || continue
                color_echo $YELLOW "[INFO] Aplicando patch $p..." | tee -a "$log"
                patch -p1 < "$p" 2>&1 | tee -a "$log"
            done
        fi
    }

    PKGDIR="$PKG/$NAME-$VERSION"; MANIFEST="$WORK/$NAME-$VERSION.list"; TAR="$PKGS_DIR/$NAME-$VERSION.tar.gz"

    case "$do_command" in
        install)
            install_dependencies "$NAME"
            download_and_extract
            rm -rf "$PKGDIR"; mkdir -p "$PKGDIR"
            fakeroot bash -c "export DESTDIR=\"$PKGDIR\"; build" 2>&1 | tee -a "$log"
            ( cd "$PKGDIR" && find . -type f -o -type d | sort ) > "$MANIFEST"
            tar -czf "$TAR" -C "$PKGDIR" . 2>&1 | tee -a "$log"
            add_installed_pkg "$NAME"
            ;;
        build-only)
            download_and_extract
            rm -rf "$PKGDIR"; mkdir -p "$PKGDIR"
            bash -c "build" 2>&1 | tee -a "$log"
            ;;
        remove)
            if [ -f "$MANIFEST" ]; then
                tac "$MANIFEST" | while read -r f; do
                    target="/${f#./}"
                    [ -f "$target" ] && sudo rm -f "$target"
                    [ -d "$target" ] && sudo rmdir --ignore-fail-on-non-empty "$target" 2>/dev/null || true
                done
            fi
            remove || true
            remove_installed_pkg "$NAME"
            ;;
    esac
}

process_directory() {
    local dir="$1"
    local cmd="$2"
    local recipes=()
    for recipe in "$dir"/*/build.sh; do [ -f "$recipe" ] || continue; recipes+=("$recipe"); done
    if [ "$PARALLEL" -gt 1 ]; then
        printf "%s\n" "${recipes[@]}" | xargs -n1 -P"$PARALLEL" -I{} bash -c "process_recipe \"{}\" \"$cmd\""
    else
        for r in "${recipes[@]}"; do process_recipe "$r" "$cmd"; done
    fi
}

build_all() { for c in base x11 extra desktop; do [ -d "$REPO/$c" ] || continue; process_directory "$REPO/$c" "install"; done; }
rebuild_system() {
    for c in base x11 extra desktop; do
        [ -d "$REPO/$c" ] || continue
        for r in "$REPO/$c"/*/build.sh; do [ -f "$r" ] || continue; process_recipe "$r" "build-only"; done
    done
}
clean_pkgs() { rm -rf "$PKG" "$PKGS_DIR"; mkdir -p "$PKG" "$PKGS_DIR"; }

# ===================== CLI =====================
CMD="$1"; TARGET="$2"
case "$CMD" in
    install|remove|build-only)
        [ -z "$TARGET" ] && { echo "Falta argumento <receita|subdiretorio>"; exit 1; }
        if [ -d "$TARGET" ]; then process_directory "$TARGET" "$CMD"
        elif [ -f "$TARGET" ]; then process_recipe "$TARGET" "$CMD"
        else echo "[ERRO] Arquivo ou diretório não encontrado: $TARGET"; exit 1
        fi
        ;;
    build-all) build_all ;;
    rebuild-system) rebuild_system ;;
    clean-pkgs) clean_pkgs ;;
    list) list_installed_pkgs ;;
    remove-orphans) remove_orphans ;;
    *) echo "Uso: $0 {install|remove|build-only|build
