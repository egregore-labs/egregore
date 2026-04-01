Configure environment variables for current project.

## What to do

1. Check which env vars are required/optional
2. Show which are missing
3. Prompt to add missing keys
4. Write to .env file

## Example

```
> /env

Checking .env...

Required for Tristero:
  OPENROUTER_API_KEY  ✗ missing
  OPENAI_API_KEY      ✗ missing

Optional:
  LLM_MODEL           ✓ set (anthropic/claude-3.5-sonnet)

To add missing keys:
  1. Get OpenRouter key from: https://openrouter.ai/keys
  2. Get OpenAI key from: https://platform.openai.com/api-keys

Paste your OPENROUTER_API_KEY (or 'skip'):
> sk-or-...

✓ Added to .env

Paste your OPENAI_API_KEY (or 'skip'):
> sk-...

✓ Added to .env

Environment ready.
```

## Next

You're ready to work. Run `/activity` to see recent activity.
