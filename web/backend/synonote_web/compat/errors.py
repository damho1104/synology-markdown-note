from __future__ import annotations


class CLIError(Exception):
    EXIT_CODES = {
        "INVALID_ARGUMENT": 2, "OUTPUT_EXISTS": 2, "NOT_FOUND": 2,
        "TITLE_CONFLICT": 3, "AMBIGUOUS_TARGET": 3,
        "UNSUPPORTED_DOCUMENT_TYPE": 4, "INVALID_SOURCE": 4,
        "AUTH_REQUIRED": 5, "OTP_REQUIRED": 5, "CREDENTIAL_STORE_UNAVAILABLE": 5,
        "REMOTE_CHANGED": 6, "WRITE_UNCERTAIN": 7,
        "REMOTE_ERROR": 8, "TRANSPORT_ERROR": 8,
        "UNSUPPORTED_MARKDOWN_FEATURE": 9,
    }

    def __init__(self, code: str, message: str, **details: object):
        super().__init__(message)
        self.code, self.details = code, details

    @property
    def exit_code(self) -> int:
        return self.EXIT_CODES.get(self.code, 8)
