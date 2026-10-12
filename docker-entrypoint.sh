#!/bin/sh
# `docker run <image> --config config.json --output results` has no command,
# so default to `run` when invoked with no args or only flags.
case "${1:-}" in
    ""|-*) set -- run "$@" ;;
esac
exec /app/run.sh "$@"
