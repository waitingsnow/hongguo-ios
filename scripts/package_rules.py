"""Path checks for source archives and unsigned IPAs."""
import unicodedata


class ValidationError(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise ValidationError(message)


def archive_parts(name):
    parts = name.removesuffix("/").split("/")
    require(all(part and part not in {".", ".."} for part in parts)
            and "\\" not in name and "\x00" not in name, "Unsafe archive path")
    return tuple(unicodedata.normalize("NFC", part).casefold() for part in parts)


def private_path(parts):
    signing_extensions = (
        ".mobileprovision", ".provisionprofile", ".cer", ".crt", ".der",
        ".pem", ".key", ".p12", ".pfx", ".p8", ".pkcs12", ".p7b", ".p7c",
        ".csr", ".certsigningrequest", ".keychain", ".keychain-db", ".xcent",
    )
    return (
        parts[0] == "local"
        or parts[-2:] == ("configuration", "local.xcconfig")
        or any(part in {".git", ".env", "_codesignature", "coderesources", "sc_info"}
               or part.startswith(".env.")
               or part.endswith(signing_extensions) for part in parts)
    )
