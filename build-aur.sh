#!/usr/bin/env bash
# build-aur.sh - AUR local-repository helpers for build.sh
#
# Sourced by build.sh (not executed directly). build.sh runs as root with
# `set -euo pipefail` and provides SCRIPT_DIR, SUDO_USER, BUILD_LOG, and the
# info/warn/error helpers. The functions here build a fixed set of
# genuine-AUR packages into a local pacman repo and emit an auditable
# manifest. See docs/aur-local-repo-spec.org.
#
# The pure helpers (package lists, stanza/manifest rendering, staged
# replace, preflight) carry no side effects and are unit-tested in
# tests/unit/test_build_aur.bats. The build_aur_packages orchestrator and
# aur_manifest_append need root + network + makepkg, so they are covered by
# the build integration test and the manual verification checklist instead.

#############################
# Package sets (single source of truth)
#############################

# The v1 genuine-AUR build set: packages with no exact official-repo match
# whose runtime + make deps all resolve from official / archzfs / the baked
# local repo (the v1 dependency gate). paru (second helper) and
# mkinitcpio-firmware (pulls AUR firmware deps) are deferred to vNext.
# Audited 2026-06-09. This list is the one place the set is named; build.sh
# reads it for the package-list append, and the manifest records what
# actually shipped.
aur_v1_packages() {
    printf '%s\n' \
        downgrade \
        yay \
        informant \
        zrepl \
        pacman-cleanup-hook \
        sanoid \
        zfs-auto-snapshot \
        topgrade \
        ventoy-bin
}

# Official `extra`-repo packages that the audit reclassified out of the AUR.
# These are NOT built — they go straight into packages.x86_64 and install
# from the normal repos. Listed here so build.sh has one source for them.
aur_official_packages() {
    printf '%s\n' \
        arch-wiki-lite \
        rate-mirrors \
        arch-audit \
        btop \
        duf \
        dust \
        procs
}

#############################
# Pacman-config rendering
#############################

# Render the [aur] pacman repo stanza for the given Server value, with a
# leading blank line so it appends cleanly after an existing stanza (the
# same shape as build.sh's [archzfs] block). SigLevel = Optional TrustAll:
# the repo is trusted by construction (we built it on this host); GPG
# signing is vNext. The Server differs per namespace — a build-host
# absolute file:// path for profile/pacman.conf, file:///usr/share/aur-packages
# for the live-runtime config.
aur_repo_stanza() {
    local server="$1"
    printf '\n[aur]\nSigLevel = Optional TrustAll\nServer = %s\n' "$server"
}

#############################
# Manifest rendering (TSV)
#############################

# Emit the manifest column header. Nine tab-separated columns; keep in lockstep
# with aur_manifest_row.
aur_manifest_header() {
    printf 'name\tpkgbase\tfilename\tpkgver\tpkgrel\tcommit\tsource_url\ttimestamp\tsha256\n'
}

# Format one manifest row from nine positional fields, tab-separated. Pure
# formatter so the column layout is unit-testable without a real build;
# aur_manifest_append gathers the field values and calls this.
aur_manifest_row() {
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@"
}

#############################
# Filesystem helpers
#############################

# Print the basename of the single *.pkg.tar.zst in $1. Returns 1 (empty
# output) when the directory holds no package file — used both to locate a
# freshly-built package and as the build-failure signal when makepkg
# produced nothing.
aur_pkgfile_name() {
    local dir="$1" f
    f=$(find "$dir" -maxdepth 1 -name '*.pkg.tar.zst' -print -quit 2>/dev/null)
    [[ -n "$f" ]] || return 1
    basename "$f"
}

# Staged replacement: move $staging into place at $repo_dir. Caller stages
# on the same filesystem (a sibling dir), so this is a local rename. The
# rm/mv window is not strictly atomic, but the build only calls this after
# every package built, repo-add ran, and the manifest emitted — so a
# failure earlier ships no repo, and a failure here leaves no stale repo.
# mv -T treats $repo_dir as the destination name rather than a dir to move
# into, which matters once $repo_dir has been recreated by a concurrent run.
aur_repo_replace() {
    local staging="$1" repo_dir="$2"
    rm -rf "$repo_dir"
    mv -T "$staging" "$repo_dir"
}

#############################
# Preflight
#############################

# Guard the build environment before any clone/makepkg. $1 is the invoking
# user (SUDO_USER); the rest, if given, are the commands to require
# (defaults to git/makepkg/repo-add — overridable so the unit tests stay
# host-independent). Fails with a named reason on empty/root user or a
# missing command. makepkg refuses to run as root, which is why a usable
# non-root SUDO_USER is mandatory.
aur_preflight() {
    local sudo_user="$1"
    shift
    local required=("$@")
    [[ ${#required[@]} -gt 0 ]] || required=(git makepkg repo-add)

    if [[ -z "$sudo_user" ]]; then
        echo "AUR build preflight: SUDO_USER is not set — run build.sh via sudo" >&2
        return 1
    fi
    if [[ "$sudo_user" == "root" ]]; then
        echo "AUR build preflight: invoking user is root; makepkg refuses to run as root" >&2
        return 1
    fi
    local cmd
    for cmd in "${required[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "AUR build preflight: required command not found: $cmd" >&2
            return 1
        fi
    done
    return 0
}

#############################
# Build orchestrator (impure)
#############################

# Append one manifest row for the package just built into $pkgdir and
# collected into $staging. Reads the version straight from the package
# metadata (pacman -Qp) so a dash in the package name can't confuse a
# filename parse, and records the AUR commit, source URL, build timestamp,
# and SHA256.
aur_manifest_append() {
    local staging="$1" pkgdir="$2" pkg="$3"
    local filename commit sha256 nameversion pkgname fullver pkgver pkgrel timestamp source_url

    filename=$(aur_pkgfile_name "$pkgdir") || return 1
    commit=$(git -C "$pkgdir" rev-parse HEAD 2>/dev/null || echo unknown)
    sha256=$(sha256sum "$staging/$filename" | awk '{print $1}')
    nameversion=$(pacman -Qp "$staging/$filename" 2>/dev/null)
    pkgname=${nameversion%% *}
    fullver=${nameversion##* }
    pkgver=${fullver%-*}
    pkgrel=${fullver##*-}
    timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    source_url="https://aur.archlinux.org/${pkg}.git"

    aur_manifest_row "$pkgname" "$pkg" "$filename" "$pkgver" "$pkgrel" \
        "$commit" "$source_url" "$timestamp" "$sha256" >> "$staging/manifest.tsv"
}

# Build the v1 AUR set into a local pacman repo at $repo_dir (default
# $SCRIPT_DIR/aur-packages). Clones each package from the AUR and runs
# makepkg as $SUDO_USER (makepkg can't run as root), collects the built
# package, appends a manifest row, then builds the repo db with repo-add
# and atomically-ish swaps the staging dir into place. On any failure
# error() names the package + phase + log path and no repo ships. Relies on
# build.sh's info/warn/error and globals.
build_aur_packages() {
    local repo_dir="${1:-${SCRIPT_DIR:-.}/aur-packages}"
    local staging="${repo_dir}.staging"
    local sudo_user="${SUDO_USER:-}"
    local -a packages
    mapfile -t packages < <(aur_v1_packages)

    aur_preflight "$sudo_user" || error "AUR build preflight failed (see above)"

    if [[ ${#packages[@]} -eq 0 ]]; then
        warn "No AUR packages in the v1 set — skipping local repo creation"
        return 0
    fi

    local build_dir
    build_dir="$(sudo -u "$sudo_user" mktemp -d /tmp/aur-build.XXXXXX)" \
        || error "AUR build: could not create build dir as $sudo_user"
    # shellcheck disable=SC2064  # expand build_dir now so RETURN cleans this dir
    trap "rm -rf '$build_dir'" RETURN

    rm -rf "$staging"
    mkdir -p "$staging"
    aur_manifest_header > "$staging/manifest.tsv"

    local pkg
    for pkg in "${packages[@]}"; do
        info "Building AUR package: $pkg"
        sudo -u "$sudo_user" git clone --depth 1 \
            "https://aur.archlinux.org/${pkg}.git" "$build_dir/${pkg}" \
            || error "AUR clone failed: $pkg (see ${BUILD_LOG:-build log})"
        sudo -u "$sudo_user" bash -c \
            "cd '$build_dir/${pkg}' && makepkg -s --noconfirm --needed" \
            || error "AUR build failed: $pkg (makepkg; see ${BUILD_LOG:-build log})"
        cp "$build_dir/${pkg}"/*.pkg.tar.zst "$staging/" \
            || error "AUR collect failed: $pkg (no package file produced)"
        aur_manifest_append "$staging" "$build_dir/${pkg}" "$pkg" \
            || error "AUR manifest failed: $pkg"
    done

    repo-add "$staging/aur.db.tar.gz" "$staging"/*.pkg.tar.zst \
        || error "repo-add failed (see ${BUILD_LOG:-build log})"

    aur_repo_replace "$staging" "$repo_dir"

    local count
    count=$(find "$repo_dir" -maxdepth 1 -name '*.pkg.tar.zst' | wc -l)
    info "AUR local repo ready: $repo_dir ($count packages)"
}
