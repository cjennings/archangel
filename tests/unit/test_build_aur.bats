#!/usr/bin/env bats
# Unit tests for build-aur.sh — the AUR local-repo build helpers.
#
# Only the pure, side-effect-free helpers are unit-tested here. The
# build_aur_packages orchestrator clones from the AUR, runs makepkg as
# $SUDO_USER, and needs root + network, so it is exercised by the build
# integration test and the manual verification checklist, not bats.

setup() {
    # shellcheck disable=SC1091
    source "${BATS_TEST_DIRNAME}/../../build-aur.sh"
}

#############################
# aur_v1_packages — single source of truth for the v1 build set
#############################

@test "aur_v1_packages lists the nine audited v1 packages" {
    run aur_v1_packages
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | wc -l)" -eq 9 ]
    for pkg in downgrade yay informant zrepl pacman-cleanup-hook \
               sanoid zfs-auto-snapshot topgrade ventoy-bin; do
        [[ "$output" == *"$pkg"* ]]
    done
}

@test "aur_v1_packages excludes the vNext-deferred packages" {
    run aur_v1_packages
    [ "$status" -eq 0 ]
    # paru (second helper) and mkinitcpio-firmware (AUR-of-AUR deps) are vNext
    [[ "$output" != *"paru"* ]]
    [[ "$output" != *"mkinitcpio-firmware"* ]]
}

@test "aur_v1_packages emits one package per line" {
    run aur_v1_packages
    # No line carries two names (no embedded spaces)
    while IFS= read -r line; do
        [[ "$line" != *" "* ]]
    done <<< "$output"
}

#############################
# aur_official_packages — official extra packages, not built
#############################

@test "aur_official_packages lists the audited official extra set" {
    run aur_official_packages
    [ "$status" -eq 0 ]
    for pkg in arch-wiki-lite rate-mirrors arch-audit btop duf dust procs; do
        [[ "$output" == *"$pkg"* ]]
    done
}

@test "aur_official_packages does not overlap the AUR build set" {
    local official aur
    official=$(aur_official_packages)
    aur=$(aur_v1_packages)
    while IFS= read -r pkg; do
        [[ -n "$pkg" ]] || continue
        [[ "$aur" != *"$pkg"* ]]
    done <<< "$official"
}

#############################
# aur_repo_stanza — renders the [aur] pacman stanza
#############################

@test "aur_repo_stanza renders header, SigLevel, and the given Server" {
    run aur_repo_stanza "file:///usr/share/aur-packages"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[aur]"* ]]
    [[ "$output" == *"SigLevel = Optional TrustAll"* ]]
    [[ "$output" == *"Server = file:///usr/share/aur-packages"* ]]
}

@test "aur_repo_stanza uses the build-host path when given one" {
    run aur_repo_stanza "file:///home/build/archangel/aur-packages"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Server = file:///home/build/archangel/aur-packages"* ]]
    [[ "$output" != *"/usr/share/aur-packages"* ]]
}

#############################
# aur_manifest_header / aur_manifest_row — TSV manifest formatting
#############################

@test "aur_manifest_header emits nine tab-separated columns" {
    run aur_manifest_header
    [ "$status" -eq 0 ]
    local cols
    cols=$(echo "$output" | awk -F'\t' '{print NF}')
    [ "$cols" -eq 9 ]
    [[ "$output" == *"name"* ]]
    [[ "$output" == *"pkgver"* ]]
    [[ "$output" == *"commit"* ]]
    [[ "$output" == *"sha256"* ]]
}

@test "aur_manifest_row formats nine fields as one tab-separated line" {
    run aur_manifest_row yay yay yay-12.0-1-x86_64.pkg.tar.zst 12.0 1 \
        abc123 https://aur.archlinux.org/yay.git 2026-06-09T19:00:00 deadbeef
    [ "$status" -eq 0 ]
    local cols
    cols=$(echo "$output" | awk -F'\t' '{print NF}')
    [ "$cols" -eq 9 ]
    [[ "$output" == *$'yay\tyay\tyay-12.0-1'* ]]
    [[ "$output" == *"abc123"* ]]
    [[ "$output" == *"deadbeef"* ]]
}

@test "aur_manifest_row keeps fields aligned to the header columns" {
    local header row hcols rcols
    header=$(aur_manifest_header)
    row=$(aur_manifest_row a b c d e f g h i)
    hcols=$(echo "$header" | awk -F'\t' '{print NF}')
    rcols=$(echo "$row" | awk -F'\t' '{print NF}')
    [ "$hcols" -eq "$rcols" ]
}

#############################
# aur_pkgfile_name — find the built package file in a dir
#############################

@test "aur_pkgfile_name returns the basename of the built package" {
    local d
    d=$(mktemp -d)
    touch "$d/yay-12.0-1-x86_64.pkg.tar.zst"
    run aur_pkgfile_name "$d"
    [ "$status" -eq 0 ]
    [ "$output" = "yay-12.0-1-x86_64.pkg.tar.zst" ]
    rm -rf "$d"
}

@test "aur_pkgfile_name returns 1 when no package file is present" {
    local d
    d=$(mktemp -d)
    run aur_pkgfile_name "$d"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    rm -rf "$d"
}

#############################
# aur_repo_replace — staged replacement, same filesystem
#############################

@test "aur_repo_replace moves staging into place and removes staging" {
    local parent staging repo
    parent=$(mktemp -d)
    staging="$parent/aur.staging"
    repo="$parent/aur"
    mkdir -p "$staging"
    touch "$staging/new.pkg.tar.zst"

    aur_repo_replace "$staging" "$repo"

    [ -f "$repo/new.pkg.tar.zst" ]
    [ ! -e "$staging" ]
    rm -rf "$parent"
}

@test "aur_repo_replace leaves no stale package from a prior repo" {
    local parent staging repo
    parent=$(mktemp -d)
    staging="$parent/aur.staging"
    repo="$parent/aur"
    mkdir -p "$repo"
    touch "$repo/stale.pkg.tar.zst"
    mkdir -p "$staging"
    touch "$staging/fresh.pkg.tar.zst"

    aur_repo_replace "$staging" "$repo"

    [ -f "$repo/fresh.pkg.tar.zst" ]
    [ ! -e "$repo/stale.pkg.tar.zst" ]
    rm -rf "$parent"
}

#############################
# aur_preflight — build-environment guard
#############################

@test "aur_preflight passes for a non-root user with present commands" {
    run aur_preflight alice bash
    [ "$status" -eq 0 ]
}

@test "aur_preflight fails when SUDO_USER is empty" {
    run aur_preflight "" bash
    [ "$status" -ne 0 ]
    [[ "$output" == *"SUDO_USER"* ]]
}

@test "aur_preflight fails when the invoking user is root" {
    run aur_preflight root bash
    [ "$status" -ne 0 ]
    [[ "$output" == *"root"* ]]
}

@test "aur_preflight fails and names a missing command" {
    run aur_preflight alice this_command_does_not_exist_xyz
    [ "$status" -ne 0 ]
    [[ "$output" == *"this_command_does_not_exist_xyz"* ]]
}
