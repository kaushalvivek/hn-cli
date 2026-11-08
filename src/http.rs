use std::collections::HashMap;

use async_trait::async_trait;
use reqwest::Method;
use reqwest::header::{HeaderMap, HeaderName, HeaderValue, SET_COOKIE};
use reqwest::redirect::Policy;
use url::Url;

use crate::error::{HnError, Result};

#[derive(Debug, Clone)]
pub struct HttpRequest {
    pub method: String,
    pub url: Url,
    pub headers: Vec<(String, String)>,
    pub body: Option<Vec<u8>>,
    pub follow_redirects: bool,
}

impl HttpRequest {
    pub fn get(url: Url) -> Self {
        Self {
            method: "GET".into(),
            url,
            headers: Vec::new(),
            body: None,
            follow_redirects: true,
        }
    }

    pub fn post(url: Url, form: &[(String, String)]) -> Self {
        Self {
            method: "POST".into(),
            url,
            headers: vec![(
                "Content-Type".into(),
                "application/x-www-form-urlencoded".into(),
            )],
            body: Some(form_encode(form).into_bytes()),
            follow_redirects: true,
        }
    }

    pub fn header(mut self, name: impl Into<String>, value: impl Into<String>) -> Self {
        self.headers.push((name.into(), value.into()));
        self
    }
}

#[derive(Debug, Clone)]
pub struct HttpResponse {
    pub status: u16,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
    pub final_url: Url,
}

impl HttpResponse {
    pub fn text(&self) -> String {
        String::from_utf8_lossy(&self.body).into_owned()
    }

    pub fn header(&self, name: &str) -> Option<&str> {
        let name = name.to_ascii_lowercase();
        self.headers
            .iter()
            .find(|(key, _)| key.eq_ignore_ascii_case(&name))
            .map(|(_, value)| value.as_str())
    }

    pub fn set_cookie_headers(&self) -> Vec<&str> {
        self.headers
            .iter()
            .filter(|(key, _)| key.eq_ignore_ascii_case("set-cookie"))
            .map(|(_, value)| value.as_str())
            .collect()
    }

    pub fn header_map(&self) -> HashMap<String, String> {
        self.headers
            .iter()
            .map(|(key, value)| (key.to_ascii_lowercase(), value.clone()))
            .collect()
    }
}

#[async_trait]
pub trait HttpTransport: Send + Sync {
    async fn send(&self, request: HttpRequest) -> Result<HttpResponse>;
}

pub struct ReqwestTransport {
    client: reqwest::Client,
    no_redirect: reqwest::Client,
}

impl ReqwestTransport {
    pub fn new() -> Result<Self> {
        let client = reqwest::Client::builder()
            .user_agent(user_agent())
            .timeout(std::time::Duration::from_secs(30))
            .build()
            .map_err(|error| HnError::Transport(error.to_string()))?;
        let no_redirect = reqwest::Client::builder()
            .user_agent(user_agent())
            .timeout(std::time::Duration::from_secs(30))
            .redirect(Policy::none())
            .build()
            .map_err(|error| HnError::Transport(error.to_string()))?;
        Ok(Self {
            client,
            no_redirect,
        })
    }
}

impl Default for ReqwestTransport {
    fn default() -> Self {
        Self::new().expect("could not build HTTP client")
    }
}

#[async_trait]
impl HttpTransport for ReqwestTransport {
    async fn send(&self, request: HttpRequest) -> Result<HttpResponse> {
        let method = Method::from_bytes(request.method.as_bytes())
            .map_err(|error| HnError::InvalidInput(format!("invalid HTTP method: {error}")))?;
        let client = if request.follow_redirects {
            &self.client
        } else {
            &self.no_redirect
        };

        let mut headers = HeaderMap::new();
        for (name, value) in &request.headers {
            let name = HeaderName::from_bytes(name.as_bytes())
                .map_err(|error| HnError::InvalidInput(format!("invalid header: {error}")))?;
            let value = HeaderValue::from_str(value)
                .map_err(|error| HnError::InvalidInput(format!("invalid header: {error}")))?;
            headers.insert(name, value);
        }

        let mut builder = client.request(method, request.url.clone()).headers(headers);
        if let Some(body) = request.body {
            builder = builder.body(body);
        }

        let response = builder
            .send()
            .await
            .map_err(|error| HnError::Transport(error.to_string()))?;
        let status = response.status().as_u16();
        let final_url = response.url().clone();
        let mut response_headers = Vec::new();
        for (name, value) in response.headers() {
            if let Ok(value) = value.to_str() {
                response_headers.push((name.as_str().to_string(), value.to_string()));
            }
        }
        // Preserve every Set-Cookie value, including when the same header is
        // repeated across redirects.
        for value in response.headers().get_all(SET_COOKIE) {
            if let Ok(value) = value.to_str()
                && !response_headers.iter().any(|(name, existing)| {
                    name.eq_ignore_ascii_case("set-cookie") && existing == value
                })
            {
                response_headers.push(("set-cookie".into(), value.to_string()));
            }
        }
        let body = response
            .bytes()
            .await
            .map_err(|error| HnError::Transport(error.to_string()))?
            .to_vec();

        Ok(HttpResponse {
            status,
            headers: response_headers,
            body,
            final_url,
        })
    }
}

pub fn user_agent() -> String {
    "hn/0.3.0 (+https://github.com/kaushalvivek/hn-cli)".into()
}

pub fn form_encode(fields: &[(String, String)]) -> String {
    let mut serializer = url::form_urlencoded::Serializer::new(String::new());
    for (key, value) in fields {
        serializer.append_pair(key, value);
    }
    serializer.finish()
}

pub fn build_url(base: &str, path: &str) -> Result<Url> {
    let base = if base.ends_with('/') {
        base.to_string()
    } else {
        format!("{base}/")
    };
    let base = Url::parse(&base)
        .map_err(|error| HnError::InvalidInput(format!("invalid base URL: {error}")))?;
    base.join(path)
        .map_err(|error| HnError::InvalidInput(format!("invalid URL: {error}")))
}

pub fn env_url(name: &str, default: &str) -> Result<Url> {
    let value = std::env::var(name).unwrap_or_else(|_| default.to_string());
    let value = if value.ends_with('/') {
        value
    } else {
        format!("{value}/")
    };
    Url::parse(&value).map_err(|error| HnError::InvalidInput(format!("invalid {name}: {error}")))
}
