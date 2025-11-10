"""Route LLM requests through PromptSail for IronClad policy enforcement

Revision ID: ironclad_routing
Revises:
Create Date: 2025-11-09

This migration updates the llm_provider table to route all LLM requests through
PromptSail, which will enforce IronClad security policies before forwarding to
the actual LLM providers.
"""

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision = 'ironclad_routing'
down_revision = None  # Will be set when integrated into Onyx's migration chain
branch_labels = None
depends_on = None


def upgrade() -> None:
    """
    Route all LLM requests through PromptSail for policy enforcement.

    This updates the api_base URL for OpenAI and Anthropic providers to route
    through the PromptSail proxy at http://promptsail:8000.
    """

    # Update OpenAI provider to route via PromptSail
    # Only update providers that are currently pointing to the default OpenAI endpoint
    op.execute("""
        UPDATE llm_provider
        SET api_base = 'http://promptsail:8000/onyx-ai/openai/v1'
        WHERE provider = 'openai'
          AND (api_base IS NULL
               OR api_base = ''
               OR api_base = 'https://api.openai.com/v1'
               OR api_base LIKE '%openai.com%');
    """)

    # Update Anthropic provider to route via PromptSail
    # Only update providers that are currently pointing to the default Anthropic endpoint
    op.execute("""
        UPDATE llm_provider
        SET api_base = 'http://promptsail:8000/onyx-ai/anthropic/v1'
        WHERE provider = 'anthropic'
          AND (api_base IS NULL
               OR api_base = ''
               OR api_base = 'https://api.anthropic.com/v1'
               OR api_base LIKE '%anthropic.com%');
    """)

    print("✅ Updated LLM providers to route through PromptSail")
    print("   - OpenAI: http://promptsail:8000/onyx-ai/openai/v1")
    print("   - Anthropic: http://promptsail:8000/onyx-ai/anthropic/v1")


def downgrade() -> None:
    """
    Revert to direct LLM connections (remove PromptSail routing).

    This removes the PromptSail proxy from the routing path, allowing direct
    connections to LLM providers (no policy enforcement).
    """

    # Revert OpenAI provider to direct connection
    op.execute("""
        UPDATE llm_provider
        SET api_base = NULL
        WHERE provider = 'openai'
          AND api_base LIKE '%promptsail%';
    """)

    # Revert Anthropic provider to direct connection
    op.execute("""
        UPDATE llm_provider
        SET api_base = NULL
        WHERE provider = 'anthropic'
          AND api_base LIKE '%promptsail%';
    """)

    print("✅ Reverted LLM providers to direct connections")
    print("   - Policy enforcement disabled")
