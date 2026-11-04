"""Executable JSON Schema v1 checks against the real Racket CLI on Windows CI.

The fixtures are synthetic; nothing is decrypted and no personal document is read.
"""
import copy
import json
import pathlib
import subprocess
import tempfile

from jsonschema import Draft202012Validator

ROOT = pathlib.Path(__file__).resolve().parents[1]
CONTRACTS = ROOT / "contracts"
ENVELOPE = json.loads((CONTRACTS / "envelope-v1.schema.json").read_text(encoding="utf-8"))
DATA = json.loads((CONTRACTS / "command-data-v1.schema.json").read_text(encoding="utf-8"))
ENVELOPE_VALIDATOR = Draft202012Validator(ENVELOPE)
DATA_VALIDATORS = {
    name: Draft202012Validator({"$defs": DATA["$defs"], "$ref": "#/$defs/" + name})
    for name in ("version", "scan", "doctor", "verify")
}
for validator in [ENVELOPE_VALIDATOR, *DATA_VALIDATORS.values()]:
    validator.check_schema(validator.schema)


def invoke(arguments, exit_codes):
    proc = subprocess.run(
        ["racket", "src/cli.rkt", *arguments],
        cwd=ROOT, capture_output=True, text=True, encoding="utf-8",
        timeout=45, check=False,
    )
    assert proc.returncode in exit_codes, (
        f"{arguments[0]} exit status unexpected: {proc.returncode}; "
        f"stderr={proc.stderr[:250]!r}"
    )
    # The CLI does not emit logs or prose on stdout.
    lines = proc.stdout.splitlines()
    assert len(lines) == 1, f"expected one JSON document, got {len(lines)} lines"
    response = json.loads(lines[0])
    ENVELOPE_VALIDATOR.validate(response)
    assert response["command"] == arguments[0]
    assert isinstance(response["data"], dict)
    if response["data"]:
        DATA_VALIDATORS[arguments[0]].validate(response["data"])
    if proc.returncode == 0:
        assert response["status"] == "ok"
    elif proc.returncode == 1:
        assert response["status"] == "partial"
    else:
        assert response["status"] == "error"
    return response


with tempfile.TemporaryDirectory(prefix="fb-contract-") as workdir:
    folder = pathlib.Path(workdir)
    original = folder / "fixture-locked.docx"
    exported = folder / "fixture-export.pdf"
    original.write_bytes(bytes.fromhex("62142365bc014400") +
                         b"E-SafeNet LOCK synthetic test only")
    exported.write_bytes(b"%PDF-1.7\nstartxref\n0\n%%EOF\n")

    version = invoke(["version"], {0})
    scan = invoke(["scan", str(folder)], {0})
    doctor = invoke(["doctor"], {0, 1})
    verify_partial = invoke(["verify", "--original", str(original),
                             "--exported", str(exported)], {1})
    verify_failed = invoke(["verify", "--original", str(original),
                            "--exported", str(original)], {4})
    usage = invoke(["scan"], {2})
    missing = invoke(["scan", str(folder / "missing-file.pdf")], {3})
    bad_hash = invoke(["verify", "--original", str(original),
                       "--exported", str(exported),
                       "--trusted-plaintext-sha256", "invalid"], {2})

    assert scan["data"]["count"] == 2
    assert verify_partial["data"]["verdict"] == "unverified"
    assert verify_failed["data"]["verdict"] == "failed"
    assert doctor["data"]["scope"] == "read-only-diagnostics"
    assert usage["errors"][0]["code"] == "invalidArguments"
    assert missing["errors"][0]["code"] == "runtimeError"
    assert bad_hash["errors"][0]["code"] == "invalidArguments"

    # Negative controls prove schema tests fail when fields drift.
    broken_envelope = copy.deepcopy(version)
    del broken_envelope["schemaVersion"]
    assert list(ENVELOPE_VALIDATOR.iter_errors(broken_envelope))
    broken_data = copy.deepcopy(scan["data"])
    del broken_data["count"]
    assert list(DATA_VALIDATORS["scan"].iter_errors(broken_data))
    false_recovery = copy.deepcopy(verify_partial["data"])
    false_recovery["verdict"] = "verified"
    assert list(DATA_VALIDATORS["verify"].iter_errors(false_recovery))

    # Output is metadata only: no raw fixture data, no machine-local full paths.
    for result in (scan, verify_partial, verify_failed):
        raw = json.dumps(result)
        assert str(folder) not in raw
        assert "synthetic test only" not in raw
        assert "plaintextBytesExported" not in raw or (
            result["data"].get("plaintextBytesExported") is False
        )

print("CLI v1 envelope and version/scan/doctor/verify payload schemas: PASS")
