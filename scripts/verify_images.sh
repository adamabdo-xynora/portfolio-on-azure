#!/usr/bin/env bash
#
# Verify the build provenance of every image pinned in images.json, before
# Terraform plans or applies anything that runs it.
#
# Each image is pinned by the digest of its multi-arch index, not by tag:
# a tag can be moved to different bytes, a digest cannot. For each one, this
# requires a SLSA provenance attestation, signed through Sigstore by GitHub
# Actions, whose certificate names exactly:
#   - the source repository,
#   - the publish workflow at the release tag (--cert-identity), and
#   - the release tag as the source ref,
# built on a GitHub-hosted runner.
#
# The check then tests itself: it verifies the same image against a wrong
# signer identity and fails if that is NOT rejected. A verifier that accepts
# anything would otherwise pass silently.
#
# Needs: gh (authenticated; GH_TOKEN in CI), jq.

set -euo pipefail

manifest="${1:-images.json}"
failures=0

for name in $(jq -r 'keys[]' "$manifest"); do
  image="$(jq -r --arg n "$name" '.[$n].image' "$manifest")"
  digest="$(jq -r --arg n "$name" '.[$n].digest' "$manifest")"
  source_repo="$(jq -r --arg n "$name" '.[$n].source_repo' "$manifest")"
  source_ref="$(jq -r --arg n "$name" '.[$n].source_ref' "$manifest")"
  signer_workflow="$(jq -r --arg n "$name" '.[$n].signer_workflow' "$manifest")"
  identity="https://github.com/${signer_workflow}@${source_ref}"
  ref="oci://${image}@${digest}"

  echo "==> ${name}: ${image}@${digest}"
  if gh attestation verify "$ref" \
      --repo "$source_repo" \
      --cert-identity "$identity" \
      --source-ref "$source_ref" \
      --deny-self-hosted-runners \
      --format json > /dev/null; then
    echo "    verified: signed by ${identity}"
  else
    echo "    FAILED: no valid provenance from ${identity}" >&2
    failures=$((failures + 1))
    continue
  fi

  # Negative control: the same attestation must not satisfy a different
  # signer identity.
  wrong="https://github.com/${signer_workflow}@refs/tags/v0.0.0-not-a-release"
  if gh attestation verify "$ref" --repo "$source_repo" --cert-identity "$wrong" \
      --format json > /dev/null 2>&1; then
    echo "    FAILED: negative control passed; verification is not enforcing the signer" >&2
    failures=$((failures + 1))
  else
    echo "    negative control: wrong signer identity rejected, as it must be"
  fi
done

if [[ "$failures" -ne 0 ]]; then
  echo "image provenance: ${failures} failure(s)" >&2
  exit 1
fi
echo "image provenance: all images verified"
