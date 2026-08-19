//! Key/value storage the application core writes through. Hosts provide the
//! implementation: SQLite/files natively, platform stores on the TVs. The core
//! never knows which is underneath.

use async_trait::async_trait;

#[derive(Debug, thiserror::Error)]
pub enum StorageError {
    #[error("{0}")]
    Backend(String),
}

#[async_trait]
pub trait Storage: Send + Sync {
    async fn get(&self, key: &str) -> Result<Option<Vec<u8>>, StorageError>;
    async fn put(&self, key: &str, value: &[u8]) -> Result<(), StorageError>;
    async fn delete(&self, key: &str) -> Result<(), StorageError>;
}
