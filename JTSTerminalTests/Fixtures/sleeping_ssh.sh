#!/bin/sh
for argument in "$@"; do
    if [ "$argument" = 'tester@lifecycle.example.test' ] &&
       [ -n "${JTS_TERMINAL_ASKPASS_SOCKET:-}" ]; then
        printf '%s\n' 'SLEEPING_SSH_READY' > "${JTS_TERMINAL_ASKPASS_SOCKET}.ready"
        break
    fi

    case "$argument" in
        deploy@jts-credential-recovery-*.example.test)
            token=${argument#deploy@jts-credential-recovery-}
            token=${token%.example.test}
            case "$token" in
                ''|*[!a-z0-9-]*)
                    continue
                    ;;
            esac
            temporary_root=${TMPDIR:-/tmp}
            marker="${temporary_root}/jts-ssh-credential-recovery-${token}/launch-count"
            rejection_marker="${temporary_root}/jts-ssh-credential-recovery-${token}/reject-every-launch"
            no_prompt_marker="${temporary_root}/jts-ssh-credential-recovery-${token}/reject-without-prompt"
            count=0
            if [ -f "$marker" ]; then
                count=$(cat "$marker")
            fi
            count=$((count + 1))
            printf '%s\n' "$count" > "$marker"
            if [ -f "$no_prompt_marker" ]; then
                printf '%s\n' "${argument}: Permission denied (publickey,password)."
                exit 255
            fi
            if [ "$count" -eq 1 ] || [ -f "$rejection_marker" ]; then
                printf '%s\n' \
                    'Permission denied, please try again.' \
                    "${argument}: Permission denied (publickey,password)."
                exit 255
            fi
            printf '%s\n' 'SSH_RECOVERY_OK'
            exec /bin/cat
            ;;
    esac
done
printf '%s\n' 'SLEEPING_SSH_READY'
exec /bin/cat
