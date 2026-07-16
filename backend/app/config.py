from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    anthropic_api_key: str
    nvidia_api_key: str = ""
    cors_origins: str = "*"

    model_config = {"env_file": ".env"}


settings = Settings()
