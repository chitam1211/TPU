# Source this file from ~/.bashrc to use: test fsub.s, test all.
# Bash already has a `test` builtin, so dispatch only ACT4 targets here.

_act4_test_cli="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/act4_cli.py"

test() {
    case "${1-}" in
        all|--list|--help|F-*|fadd.s|fsub.s|feq.s|flt.s|fle.s|fmin.s|fmax.s|\
        fmv.w.x|fmv.x.w|fsgnj.s|fsgnjn.s|fsgnjx.s|fclass.s|flw|fsw)
            python3 "$_act4_test_cli" "$@"
            ;;
        *)
            builtin test "$@"
            ;;
    esac
}
