# Dapr Workflow Issue Reproduction

This project reproduces a **critical production issue** with Dapr workflows where activities continue executing infinitely after workflow state expires, even when the workflow instance is not found.

## Real-World Production Scenario

### 🏭 **How This Happens in Production**

In production environments, we often configure **TTL (Time To Live)** on Dapr state stores to prevent workflows from consuming resources indefinitely:

```yaml
# Example: Redis state store with TTL
apiVersion: dapr.io/v1alpha1
kind: Component
metadata:
  name: statestore
spec:
  type: state.redis
  metadata:
    - name: ttlInSeconds
      value: "3600" # 1 hour TTL
```

**The Problem:**

1. **Long-running workflows** (e.g. data pipelines)
2. **Workflow execution time > TTL** (workflow takes longer than 1 hour)
3. **State expires** while workflow is still running
4. **Activities continue executing infinitely** even though workflow state is gone

### 💰 **Why This Is Expensive**

Our workflow activities often involve:

- **LLM API calls** (OpenAI, Anthropic, etc.) - $$$
- **Cloud service integrations** - $$$
- **Database operations** - Resource intensive
- **External API calls** - Rate limits + costs

**Result:** Instead of the TTL preventing infinite execution, we get:

- ❌ **Infinite LLM calls** costing hundreds/thousands of dollars
- ❌ **Infinite external API calls** hitting rate limits
- ❌ **Resource exhaustion** on our infrastructure
- ❌ **The exact opposite** of what TTL was supposed to prevent

## Issue Description

After a Dapr state store TTL expiration (or Redis/Dapr restart in our local illustration):

1. The Dapr scheduler continues sending `run-activity` messages to the sidecar
2. The sidecar reports "workflow instance not found" errors
3. **BUT** the workflow activities continue executing infinitely anyway
4. This creates an infinite loop of expensive activity executions

### ⚠️ Retry Policy Does NOT Fix This Issue

**Important Note:** This project includes retry policies on activity execution (as originally suggested by Diagrid to resolve this issue), but the problem persists:

```python
retry_policy = wf.RetryPolicy(
    first_retry_interval=timedelta(seconds=1),
    max_number_of_attempts=3,
    backoff_coefficient=2,
    max_retry_interval=timedelta(seconds=10),
    retry_timeout=timedelta(seconds=100),
)

# Applied to activities like this:
ctx.call_activity(hello_world_activity, retry_policy=retry_policy)
```

**Even with retry policies configured:**

- Activities still execute infinitely after TTL expiration
- "Workflow instance not found" errors continue
- The retry policy doesn't prevent the infinite execution loop
- This demonstrates that retry policies are not a solution to this issue

## Production Impact Examples

### 💸 **Cost Scenario:**

```
Activity: Call OpenAI GPT-4 API ($0.03 per 1K tokens)
Frequency: Every 10 seconds (due to activity execution + retries)
Duration: 24 hours before noticed
Cost: $259.20 for a single "stuck" workflow
```

### 🚨 **Scale Scenario:**

```
Workflows affected: 50 (during a Redis restart)
LLM calls per hour: 18,000
Monthly cost impact: $38,880 extra
Plus: Rate limiting affecting legitimate requests
```

## Quick Start

### Prerequisites

- Docker and docker-compose
- curl
- jq (optional, for pretty JSON output)

### Running the Reproduction

```bash
# Make the script executable (if not already)
chmod +x reproduce_issue.sh

# Run the reproduction script
./reproduce_issue.sh
```

### Manual Testing

1. **Start the services:**

   ```bash
   docker-compose up -d
   ```

2. **Create a workflow:**

   ```bash
   curl -X POST http://localhost:8999/workflow/hello \
     -H "Content-Type: application/json" \
     -d '{"instance_id": "test-workflow-123"}'
   ```

3. **Wait for execution, then simulate TTL expiration:**

   ```bash
   # Wait 45 seconds for workflow to start
   sleep 45

   # Kill Redis and Dapr (simulates TTL expiration)
   docker-compose kill redis dapr

   # Wait 10 seconds
   sleep 10

   # Restart services
   docker-compose up -d
   ```

4. **Observe the issue in logs:**

   ```bash
   # Watch for infinite activity execution
   docker-compose logs -f fastapi

   # Check for "instance not found" errors
   docker-compose logs -f dapr

   # Check scheduler activity
   docker-compose logs -f dapr-scheduler
   ```

## Project Structure

- `main.py` - FastAPI application with Dapr workflow (includes retry policies)
- `docker-compose.yml` - Multi-container setup with Dapr, Redis, scheduler
- `requirements.txt` - Python dependencies
- `reproduce_issue.sh` - Automated reproduction script
- `dapr/` - Dapr configuration files

## API Endpoints

- `GET /` - Root endpoint with API information
- `GET /health` - Health check
- `POST /workflow/hello` - Start a Hello World workflow

## Cleanup

```bash
docker-compose down
```
