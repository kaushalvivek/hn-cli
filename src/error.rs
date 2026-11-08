use thiserror::Error;

pub type Result<T> = std::result::Result<T, HnError>;

#[derive(Debug, Error)]
pub enum HnError {
    #[error("{0}")]
    InvalidInput(String),

    #[error("{0} not found")]
    NotFound(String),

    #[error("not logged in")]
    Unauthenticated,

    #[error("invalid Hacker News username or password")]
    InvalidCredentials,

    #[error("that action is not allowed for this account")]
    Unauthorized,

    #[error("{0}")]
    Unsupported(String),

    #[error("Hacker News rate-limited the request")]
    RateLimited(Option<u64>),

    #[error("Hacker News returned HTTP {0}")]
    Server(u16),

    #[error("{0}")]
    Transport(String),

    #[error("could not decode Hacker News response: {0}")]
    Decoding(String),

    #[error("cancelled")]
    Cancelled,
}

impl HnError {
    pub fn code(&self) -> &'static str {
        match self {
            HnError::InvalidInput(_) => "invalid_input",
            HnError::NotFound(_) => "not_found",
            HnError::Unauthenticated => "unauthenticated",
            HnError::InvalidCredentials => "invalid_credentials",
            HnError::Unauthorized => "unauthorized",
            HnError::Unsupported(_) => "unsupported",
            HnError::RateLimited(_) => "rate_limited",
            HnError::Server(_) => "server_error",
            HnError::Transport(_) => "transport_error",
            HnError::Decoding(_) => "decoding_error",
            HnError::Cancelled => "cancelled",
        }
    }

    pub fn payload(&self) -> serde_json::Value {
        serde_json::json!({
            "ok": false,
            "error": {
                "code": self.code(),
                "message": self.to_string(),
            }
        })
    }
}
