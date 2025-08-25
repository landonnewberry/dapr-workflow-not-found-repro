import time
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
import uvicorn
import logging
import asyncio
from datetime import datetime, timedelta
import dapr.ext.workflow as wf
from typing import Optional
import uuid
from contextlib import asynccontextmanager

# Dapr imports - using the correct workflow extension
from dapr.ext.workflow import (
    WorkflowRuntime,
    DaprWorkflowContext,
    WorkflowActivityContext,
)
from dapr.clients import DaprClient

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

workflow_runtime = WorkflowRuntime()
wf_client = wf.DaprWorkflowClient()
retry_policy = wf.RetryPolicy(
    first_retry_interval=timedelta(seconds=1),
    max_number_of_attempts=3,
    backoff_coefficient=2,
    max_retry_interval=timedelta(seconds=10),
    retry_timeout=timedelta(seconds=100),
)


# Activity function - prints "Hello world"
def hello_world_activity(ctx: WorkflowActivityContext) -> str:
    """Activity that prints Hello World with timestamp"""
    workflow_state = wf_client.get_workflow_state(ctx.workflow_id)
    if not workflow_state:
        print(
            f"No workflow state found for {ctx.workflow_id} "
            f"but activity is being executed anyways!!!!!!!!!"
        )
        return "Done"
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    message = f"Hello world! - {timestamp}"
    time.sleep(10)
    print(message)  # This will show in Docker logs
    logger.info(message)
    return message


# Workflow function - orchestrates the Hello World activity
# every second for 15 seconds
def hello_world_workflow(ctx: DaprWorkflowContext) -> str:
    """Workflow that prints Hello World every second for 15 seconds"""
    logger.info("Starting Hello World workflow")

    # Run for 15 seconds, calling activity every second
    for i in range(10):
        # Call the act10ity
        try:
            activities = [
                ctx.call_activity(hello_world_activity, retry_policy=retry_policy)
                for _ in range(3)
            ]
            _ = yield wf.when_all(activities)
        except Exception as e:
            logger.error(f"Error calling activity: {str(e)}")
            raise

    return "Done"


workflow_runtime.register_workflow(hello_world_workflow)
workflow_runtime.register_activity(hello_world_activity)


@asynccontextmanager
async def lifespan(app: FastAPI):
    """FastAPI lifespan context manager for startup and shutdown events"""
    # Startup
    await asyncio.sleep(2)  # Give more time for Dapr sidecar to start
    workflow_runtime.start()

    yield

    # Shutdown (if needed)
    workflow_runtime.shutdown()
    logger.info("Application shutting down")


# Create FastAPI app with lifespan
app = FastAPI(
    title="Dapr Workflow API",
    description=("A FastAPI application with Dapr workflow for Hello World demo"),
    version="1.0.0",
    lifespan=lifespan,
)


# Pydantic models
class WorkflowRequest(BaseModel):
    instance_id: Optional[str] = None


class WorkflowResponse(BaseModel):
    instance_id: str
    status: str
    message: str


# FastAPI Routes


@app.get("/")
async def root():
    """Root endpoint"""
    return {
        "message": "Dapr Workflow Demo API",
        "endpoints": {
            "health": "/health",
            "start_workflow": "/workflow/hello",
            "docs": "/docs",
        },
    }


@app.get("/health")
async def health_check():
    """Health check endpoint"""
    return {
        "status": "healthy",
        "message": "API and workflow runtime are running",
        "timestamp": datetime.now().isoformat(),
    }


@app.post("/workflow/hello", response_model=WorkflowResponse)
async def start_hello_workflow(request: WorkflowRequest):
    """Start the Hello World workflow"""
    try:
        # Generate instance ID if not provided
        instance_id = request.instance_id or f"hello-world-{uuid.uuid4()}"

        # Start the workflow using Dapr client
        client = DaprClient()
        try:
            wf_client.schedule_new_workflow(
                workflow=hello_world_workflow,
                instance_id=instance_id,
            )
        finally:
            client.close()

        logger.info(f"Started Hello World workflow with instance ID: {instance_id}")

        return WorkflowResponse(
            instance_id=instance_id,
            status="started",
            message="Hello World workflow started successfully",
        )

    except Exception as e:
        logger.error(f"Error starting workflow: {str(e)}")
        raise HTTPException(
            status_code=500, detail=f"Failed to start workflow: {str(e)}"
        )


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8080)
