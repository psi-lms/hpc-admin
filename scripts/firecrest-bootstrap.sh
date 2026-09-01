#!/bin/bash
# One-time FirecREST bootstrap for lms-login.psi.ch.
#
# Creates everything secret-bearing that Puppet deliberately does not manage:
#   /etc/firecrest/secrets/*            SSH private keys + service account secret
#   /etc/firecrest/keycloak-realm.json  the realm Keycloak imports on first start
#   /etc/firecrest/keycloak.env         Keycloak admin credentials
#   /var/lib/firecrest/keycloak         Keycloak's H2 data directory
#
# Run as root BEFORE the first puppet run, so `files::files` finds its parents.
# Idempotent: existing keys and secrets are kept, never regenerated.
#
# Identity model, which is the subtle part. FirecREST reads the cluster username
# from the token claim named by `username_claim`, set to "sub" in the Hiera.
# Two kinds of token have to end up carrying the right value there:
#
#   firecrest-<user>        password grant, a human logging in as themselves.
#                           Mapper: user attribute `username` -> sub.
#   firecrest-aiida-<user>  client credentials, which is how aiida-firecrest
#                           authenticates. The token's subject is the client's
#                           service account, so the cluster username is carried
#                           in an `owner` attribute on that service-account user.
#                           Mapper: user attribute `owner` -> sub.
#
# `preferred_username` is deliberately not used: Keycloak's built-in mapper
# already fills it, and for a service account it would say
# "service-account-firecrest-aiida-<user>", which is not a cluster account.
#
# See data-lms/docs/firecrest-deployment.md for the surrounding design.

set -euo pipefail

PILOT_USERS=("geiger_j")
HEALTH_CHECK_OWNER="geiger_j"   # which cluster account FirecREST's own probing acts as
REALM="lms"
SECRETS_DIR="/etc/firecrest/secrets"
APPUSER_UID=5678                # the UID the firecrest-v2 image runs as
KC_ADMIN="admin"

if [[ $EUID -ne 0 ]]; then
    echo "must run as root" >&2
    exit 1
fi
command -v openssl   >/dev/null || { echo "openssl not found" >&2; exit 1; }
command -v ssh-keygen >/dev/null || { echo "ssh-keygen not found" >&2; exit 1; }

# Keep a generated value stable across re-runs by caching it in a file.
remember() {
    local path="$1"
    if [[ ! -f "$path" ]]; then
        openssl rand -hex 24 > "$path"
        chmod 0400 "$path"
    fi
    cat "$path"
}

echo "== directories"
mkdir -p "$SECRETS_DIR" /var/lib/firecrest/keycloak
chmod 0755 /etc/firecrest
chmod 0700 "$SECRETS_DIR"
chown -R "$APPUSER_UID:$APPUSER_UID" "$SECRETS_DIR"

echo "== ssh keypairs"
declare -A PUBKEYS
for user in "${PILOT_USERS[@]}"; do
    key="$SECRETS_DIR/ssh_key_$user"
    if [[ -f "$key" ]]; then
        echo "   $user: key exists, keeping it"
    else
        ssh-keygen -t ed25519 -N '' -C "firecrest-$user@lms" -f "$key" >/dev/null
        echo "   $user: generated"
    fi
    chmod 0400 "$key" "$key.pub"
    chown "$APPUSER_UID:$APPUSER_UID" "$key" "$key.pub"
    PUBKEYS[$user]="$(cat "$key.pub")"
done

echo "== secrets"
SERVICE_ACCOUNT_SECRET="$(remember "$SECRETS_DIR/service_account_client_secret")"
chown "$APPUSER_UID:$APPUSER_UID" "$SECRETS_DIR/service_account_client_secret"

# Kept outside SECRETS_DIR: that directory is bind-mounted wholesale into the
# FirecREST container, and these belong to Keycloak, not to FirecREST.
KC_ADMIN_PASSWORD="$(remember /etc/firecrest/.kc_admin_password)"
declare -A USER_PASSWORDS HUMAN_SECRETS AIIDA_SECRETS
for user in "${PILOT_USERS[@]}"; do
    USER_PASSWORDS[$user]="$(remember "/etc/firecrest/.user_password_$user")"
    HUMAN_SECRETS[$user]="$(remember "/etc/firecrest/.client_secret_$user")"
    AIIDA_SECRETS[$user]="$(remember "/etc/firecrest/.aiida_client_secret_$user")"
done

echo "== keycloak.env"
cat > /etc/firecrest/keycloak.env <<EOF
KC_BOOTSTRAP_ADMIN_USERNAME=$KC_ADMIN
KC_BOOTSTRAP_ADMIN_PASSWORD=$KC_ADMIN_PASSWORD
EOF
chmod 0400 /etc/firecrest/keycloak.env

echo "== keycloak realm"

# Mapper writing a user attribute into the `sub` claim.
mapper() {  # $1 = user attribute to read
    cat <<EOF
{
  "name": "$1-to-sub",
  "protocol": "openid-connect",
  "protocolMapper": "oidc-usermodel-attribute-mapper",
  "config": {
    "user.attribute": "$1",
    "claim.name": "sub",
    "jsonType.label": "String",
    "access.token.claim": "true",
    "id.token.claim": "true",
    "userinfo.token.claim": "true",
    "introspection.token.claim": "true"
  }
}
EOF
}

clients_json=""
users_json=""
add() { local -n arr=$1; [[ -n "${arr}" ]] && arr+=","; arr+="$2"; }

for user in "${PILOT_USERS[@]}"; do
    # Human client: password grant, acts as the logged-in user.
    add clients_json "$(cat <<EOF
{
  "clientId": "firecrest-$user",
  "enabled": true,
  "protocol": "openid-connect",
  "publicClient": false,
  "secret": "${HUMAN_SECRETS[$user]}",
  "standardFlowEnabled": true,
  "directAccessGrantsEnabled": true,
  "serviceAccountsEnabled": false,
  "protocolMappers": [ $(mapper username) ]
}
EOF
)"
    # AiiDA client: client credentials, acts as the account named by `owner`.
    add clients_json "$(cat <<EOF
{
  "clientId": "firecrest-aiida-$user",
  "enabled": true,
  "protocol": "openid-connect",
  "publicClient": false,
  "secret": "${AIIDA_SECRETS[$user]}",
  "standardFlowEnabled": false,
  "directAccessGrantsEnabled": false,
  "serviceAccountsEnabled": true,
  "protocolMappers": [ $(mapper owner) ]
}
EOF
)"
    add users_json "$(cat <<EOF
{
  "username": "$user",
  "enabled": true,
  "emailVerified": true,
  "credentials": [
    {"type": "password", "value": "${USER_PASSWORDS[$user]}", "temporary": false}
  ]
}
EOF
)"
    add users_json "$(cat <<EOF
{
  "username": "service-account-firecrest-aiida-$user",
  "enabled": true,
  "serviceAccountClientId": "firecrest-aiida-$user",
  "attributes": {"owner": ["$user"]}
}
EOF
)"
done

# FirecREST's own health probing.
add clients_json "$(cat <<EOF
{
  "clientId": "firecrest-health-check",
  "enabled": true,
  "protocol": "openid-connect",
  "publicClient": false,
  "secret": "$SERVICE_ACCOUNT_SECRET",
  "standardFlowEnabled": false,
  "directAccessGrantsEnabled": false,
  "serviceAccountsEnabled": true,
  "protocolMappers": [ $(mapper owner) ]
}
EOF
)"
add users_json "$(cat <<EOF
{
  "username": "service-account-firecrest-health-check",
  "enabled": true,
  "serviceAccountClientId": "firecrest-health-check",
  "attributes": {"owner": ["$HEALTH_CHECK_OWNER"]}
}
EOF
)"

cat > /etc/firecrest/keycloak-realm.json <<EOF
{
  "realm": "$REALM",
  "enabled": true,
  "sslRequired": "none",
  "clients": [ $clients_json ],
  "users": [ $users_json ]
}
EOF
chmod 0444 /etc/firecrest/keycloak-realm.json

python3 -m json.tool /etc/firecrest/keycloak-realm.json >/dev/null \
    && echo "   realm JSON is valid" \
    || { echo "   realm JSON is INVALID, fix before starting keycloak" >&2; exit 1; }

echo
echo "=============================================================="
echo " Generated credentials. Record these now."
echo "=============================================================="
echo " Keycloak admin         : $KC_ADMIN / $KC_ADMIN_PASSWORD"
echo " firecrest-health-check : $SERVICE_ACCOUNT_SECRET"
for user in "${PILOT_USERS[@]}"; do
    echo
    echo " $user"
    echo "   keycloak password        : ${USER_PASSWORDS[$user]}"
    echo "   firecrest-$user (human)  : ${HUMAN_SECRETS[$user]}"
    echo "   firecrest-aiida-$user    : ${AIIDA_SECRETS[$user]}   <- for verdi computer configure"
done
echo
echo "=============================================================="
echo " NEXT: append each public key to that user's authorized_keys."
echo " Not done here, since it writes into a user's home directory."
echo "=============================================================="
for user in "${PILOT_USERS[@]}"; do
    echo
    echo "  echo '${PUBKEYS[$user]}' >> /mnt/home/$user/.ssh/authorized_keys"
done
echo
echo "Then: commit and push the Hiera change, run puppet on this node only,"
echo "  sudo /opt/puppetlabs/bin/puppet agent -t --noop   # inspect first"
echo "  sudo /opt/puppetlabs/bin/puppet agent -t"
echo "  sudo systemctl daemon-reload"
echo "  sudo systemctl start keycloak      # wait until healthy"
echo "  sudo systemctl start firecrest-api"
