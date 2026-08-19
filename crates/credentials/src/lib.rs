//! Secrets are stored apart from ordinary settings: provider API keys never become
//! plain store entries. Native hosts back this with Stronghold/OS keychains; TV
//! hosts must decide between platform secure storage and revocable pairing tokens
//! (docs/migration/01-parity-checklist.md).

use async_trait::async_trait;

#[derive(Debug, thiserror::Error)]
pub enum CredentialError {
    #[error("{0}")]
    Backend(String),
}

#[async_trait]
pub trait CredentialStore: Send + Sync {
    async fn get(&self, name: &str) -> Result<Option<String>, CredentialError>;
    async fn set(&self, name: &str, value: &str) -> Result<(), CredentialError>;
    async fn delete(&self, name: &str) -> Result<(), CredentialError>;
}
