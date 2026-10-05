"""Optional memory-only publisher, appended to warden-remote.py by the Mac.

Uses Python's standard library and the system OpenSSL library. No remote files,
packages, provider settings, keys or services are installed or modified.
"""
import base64
import ctypes
import ctypes.util
import hashlib
import hmac
import urllib.error
import urllib.request
from urllib.parse import urlsplit


def feed_encode(value):
    return base64.urlsafe_b64encode(value).decode().rstrip("=")


class FeedCipher:
    """OpenSSL's EVP AES-256-GCM API, not a Python cryptographic implementation."""
    def __init__(self, secret, room):
        raw = base64.urlsafe_b64decode(secret + "=" * (-len(secret) % 4))
        if len(raw) != 32:
            raise ValueError("Invalid Warden pairing key")
        extracted = hmac.new(room.encode(), raw, hashlib.sha256).digest()
        self.key = hmac.new(extracted, b"warden.feed.toMac.v1\x01", hashlib.sha256).digest()
        name = ctypes.util.find_library("crypto")
        if not name:
            raise RuntimeError("The system OpenSSL library is unavailable; nothing was installed")
        self.lib = ctypes.CDLL(name)
        pointer, integer = ctypes.c_void_p, ctypes.c_int
        signatures = {
            "EVP_CIPHER_CTX_new": (pointer, []),
            "EVP_CIPHER_CTX_free": (None, [pointer]),
            "EVP_aes_256_gcm": (pointer, []),
            "EVP_EncryptInit_ex": (integer, [pointer, pointer, pointer, pointer, pointer]),
            "EVP_EncryptUpdate": (integer, [pointer, pointer, ctypes.POINTER(integer), pointer, integer]),
            "EVP_EncryptFinal_ex": (integer, [pointer, pointer, ctypes.POINTER(integer)]),
            "EVP_CIPHER_CTX_ctrl": (integer, [pointer, integer, integer, pointer]),
        }
        for name, (result, arguments) in signatures.items():
            function = getattr(self.lib, name)
            function.restype, function.argtypes = result, arguments

    def seal(self, value):
        context = self.lib.EVP_CIPHER_CTX_new()
        if not context:
            raise RuntimeError("Could not create OpenSSL cipher")
        nonce, count = os.urandom(12), ctypes.c_int()
        output, tag = ctypes.create_string_buffer(len(value) + 16), ctypes.create_string_buffer(16)
        try:
            operations = [
                self.lib.EVP_EncryptInit_ex(context, self.lib.EVP_aes_256_gcm(), None, self.key, nonce),
                self.lib.EVP_EncryptUpdate(context, output, ctypes.byref(count), value, len(value)),
            ]
            length = count.value
            operations.append(self.lib.EVP_EncryptFinal_ex(context, ctypes.byref(output, length), ctypes.byref(count)))
            length += count.value
            operations.append(self.lib.EVP_CIPHER_CTX_ctrl(context, 0x10, 16, tag))  # EVP_CTRL_AEAD_GET_TAG
            if any(result != 1 for result in operations):
                raise RuntimeError("OpenSSL could not encrypt the Warden state")
            return feed_encode(nonce + output.raw[:length] + tag.raw)
        finally:
            self.lib.EVP_CIPHER_CTX_free(context)


class FeedStopped(Exception):
    pass


def feed_request(config, method, value=None):
    body = compact(value).encode() if value is not None else None
    request = urllib.request.Request(config["relay"].rstrip("/") + "/v1/feeds/" + config["room"], data=body,
        method=method, headers={"Authorization": "Bearer " + config["publisherToken"], "Content-Type": "application/json",
                               "User-Agent": "Warden/0.4"})
    try:
        # Never follow a redirect with the publisher credential.
        class NoRedirect(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, *args):
                return None
        with urllib.request.build_opener(NoRedirect).open(request, timeout=15) as response:
            result = json.loads(response.read(4096))
        if result.get("stop"):
            raise FeedStopped()
        return result
    except urllib.error.HTTPError as error:
        if error.code in (401, 403, 404, 410):
            raise FeedStopped() from None
        raise


def feed_main(config):
    if sys.platform != "linux" or not pathlib.Path("/proc").is_dir():
        sys.stderr.write("Warden requires Linux and Python 3.8 or newer.\n")
        return 1
    relay = urlsplit(config["relay"])
    if relay.scheme != "https" and not config.get("localTest"):
        raise ValueError("A verified HTTPS relay is required")
    cipher = FeedCipher(config["key"], config["room"])
    # Preflight before detaching or starting provider-reader threads. Failed setup leaves no process behind.
    ready = feed_request(config, "GET")
    if not ready.get("challenge"):
        raise RuntimeError("The Mac has not connected to this feed yet")
    if os.fork():
        print("Warden's temporary collector started. No remote files or packages were installed.", flush=True)
        return 0
    os.setsid()
    if os.fork():
        os._exit(0)
    signal.signal(signal.SIGHUP, signal.SIG_IGN)
    with open(os.devnull, "r+b", buffering=0) as null:
        for descriptor in (0, 1, 2):
            os.dup2(null.fileno(), descriptor)
    # All code, tokens and keys remain in this process's memory.
    collector = Collector(usage_providers=ready.get("usageProviders", []))
    challenge, sequence, last_success = ready["challenge"], 0, time.monotonic()
    try:
        while time.monotonic() - last_success < 86400:
            sequence += 1
            envelope = {"challenge": challenge, "sequence": sequence, "snapshot": collector.snapshot()}
            box = cipher.seal(compact(envelope).encode())
            try:
                response = feed_request(config, "POST", {"box": box})
                last_success = time.monotonic()
                challenge = response.get("challenge", challenge)
                collector.usage_providers = response.get("usageProviders", [])
            except (urllib.error.URLError, OSError, ValueError):
                pass
            time.sleep(20)
    except FeedStopped:
        pass
    os._exit(0)
