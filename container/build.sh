#!/usr/bin/env bash
set -e

SELF_NAME=$0

die() {
    echo >&2
    echo >&2 "ERROR: $*"
    echo >&2
    exit 1
}

die_usage() {
    usage >&2
    die "$*"
}

usage() {
    cat <<EOF
Usage: $SELF_NAME [--platform PF] <version>
... where <version> is a 'x.y' version such as 8.0.

--platform   override the default platform for the build container.
--overlay-cache
             let image builder use its cache for image overlays (don't force --no-cache)
--add-repo NICK:DIR
             add specified directory as a repo
--bootstrap  generate a bootstrap image, needed to build xcp-ng-release.
--isarpm     (internal) generate an image suitable for the ISARPM build system.
--layer-repo DIR
             (Kitten only) install every package from the local repo DIR, which
             also holds packages.list, the names to install, instead of from
             the live repos.
EOF
}

PLATFORM=
EXTRA_ARGS=()
OVERLAY_CACHE=0
VARIANT=build
REPO=
LAYER_REPO=
while [ $# -ge 1 ]; do
    case "$1" in
        --help|-h)
            usage
            exit 0
            ;;
        --platform)
            [ $# -ge 2 ] || die_usage "$1 needs an argument"
            PLATFORM="$2"
            shift
            ;;
        --overlay-cache)
            OVERLAY_CACHE=1
            ;;
        --bootstrap)
            VARIANT=bootstrap
            ;;
        --isarpm)
            VARIANT=isarpm
            ;;
        --add-repo)
            [ $# -ge 2 ] || die_usage "$1 needs an argument"
            REPO="$2"
            shift
            ;;
        --layer-repo)
            [ $# -ge 2 ] || die_usage "$1 needs an argument"
            LAYER_REPO="$2"
            shift
            ;;
        -*)
            die_usage "unknown flag '$1'"
            ;;
        *)
            break
            ;;
    esac
    shift
done

[ -n "$1" ] || die_usage "version parameter missing"

if [ $OVERLAY_CACHE = 0 ]; then
    EXTRA_ARGS+=(--no-cache)
fi

case "$1" in
    8.*)
        [ $VARIANT = build ] || die "--variant is only supported for XCP-ng 9.0 and newer"
        ;;
esac

RUNNER=""
if [ -n "$XCPNG_OCI_RUNNER" ]; then
    RUNNER="$XCPNG_OCI_RUNNER"
else
    SUPPORTED_RUNNERS="docker podman"
    for COMMAND in $SUPPORTED_RUNNERS; do
        if command -v $COMMAND >/dev/null; then
            RUNNER="$COMMAND"
            break
        fi
    done
    if [ -z "$RUNNER" ]; then
        echo >&2 "cannot find a supported runner: $SUPPORTED_RUNNERS"
        exit 1
    fi
fi

cd $(dirname "$0")

ALMA_VERSION=
CENTOS_VERSION=
case "$1" in
    9.*)
        DOCKERFILE=Dockerfile-9.x
        ALMA_VERSION=10.0
        case $(uname -m) in
            x86_64)
                : ${PLATFORM:=linux/amd64/v2}
                ;;
            aarch64)
                : ${PLATFORM:=linux/aarch64}
                ;;
            riscv64)
                : ${PLATFORM:=linux/riscv64}
                ;;
        esac
        ;;
    8.*)
        DOCKERFILE=Dockerfile-8.x
        : ${PLATFORM:=linux/amd64}
        ;;
    *)
        echo >&2 "Unsupported release '$1'"
        exit 1
        ;;
esac

[ -n "$PLATFORM" ] || die "Cannot determine container platform to use, try --platform"

case "$PLATFORM" in
    linux/amd64)
        RPMARCH=x86_64
        ;;
    linux/amd64/v2)
        RPMARCH=x86_64_v2
        ;;
    linux/aarch64)
        RPMARCH=aarch64
        ;;
    linux/riscv64)
        # No AlmaLinux 10.x for riscv64: build on Kitten
        RPMARCH=riscv64
        [ "$DOCKERFILE" = Dockerfile-9.x ] && DOCKERFILE=Dockerfile-9.x-kitten
        ;;
    *)
        echo >&2 "Unsupported platform '$PLATFORM'"
        exit 1
        ;;
esac

if [ "$RUNNER" = "podman" ]; then
    EXTRA_ARGS+=("--security-opt" "label=disable")
fi

case $VARIANT in
    build)
        TAG=${1}
        ;;
    bootstrap)
        TAG=${1}-bootstrap
        EXTRA_ARGS+=( "--build-arg" "VARIANT=bootstrap" )
        ;;
    isarpm)
        TAG=${1}-isarpm
        EXTRA_ARGS+=( "--build-arg" "VARIANT=isarpm" )
        ;;
    *)
        echo >&2 "Unsupported --variant '$VARIANT'"
        ;;
esac

# handle --layer-repo: its .repo file, and that of --add-repo, go to a
# directory the Dockerfile makes the only reposdir while installing
REPOSD=
if [ -n "$LAYER_REPO" ]; then
    [ "$DOCKERFILE" = Dockerfile-9.x-kitten ] || die "--layer-repo is only supported on Kitten"
    [ -r "$LAYER_REPO/packages.list" ] || die "$LAYER_REPO/packages.list missing"
    REPOSD=$(mktemp -d)
    cat > "$REPOSD/layer.repo" <<EOF
[layer]
name=Local repository - layer from $LAYER_REPO
baseurl=file:///local-repos/layer/
enabled=1
repo_gpgcheck=0
gpgcheck=0
EOF
    EXTRA_ARGS+=(
        "-v" "$LAYER_REPO:/local-repos/layer:ro"
        "-v" "$REPOSD:/etc/xcp-ng-build-env/repos.d:ro"
        "--build-arg" "LAYER_REPO=1"
    )
fi

# handle --add-repo
if [ -n "$REPO" ]; then
    REPOCONF=$(mktemp)
    REPONICK=${REPO%:*}
    REPODIR=${REPO#*:}
    cat > $REPOCONF <<EOF
[$REPONICK]
name=Local repository - $REPONICK from $REPODIR
baseurl=file:///local-repos/$REPONICK/
enabled=1
repo_gpgcheck=0
gpgcheck=0
priority=1
EOF
    if [ -n "$REPOSD" ]; then
        mv "$REPOCONF" "$REPOSD/$REPONICK.repo"
    else
        EXTRA_ARGS+=("-v" "$REPOCONF:/etc/yum.repos.d/$REPONICK.repo:rw")
    fi
    EXTRA_ARGS+=("-v" "$REPODIR:/local-repos/$REPONICK:ro")
fi

"$RUNNER" build \
    --platform "$PLATFORM" \
    -t ghcr.io/xcp-ng/xcp-ng-build-env:${TAG} \
    --build-arg XCP_NG_BRANCH=${1} \
    --build-arg RPMARCH="$RPMARCH" \
    --ulimit nofile=1024 \
    "${EXTRA_ARGS[@]}" \
    -f $DOCKERFILE .
