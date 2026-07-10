from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    anthropic_api_key: str
    nvidia_api_key: str = ""
    redis_url: str = "redis://localhost:6381"

    model_config = {"env_file": ".env"}


settings = Settings()
