#!/usr/bin/env python3
"""
orchestrator_minimal.py avec streaming des logs en temps réel
"""

import os
import subprocess
import tempfile
from typing import Optional, Dict, Any
from fastapi import FastAPI, HTTPException, Header, File, UploadFile, Form
from fastapi.responses import StreamingResponse
import json
from pydantic import BaseModel, Field
from urllib.parse import urlparse

app = FastAPI(title="Orchestrator Deployment", version="1.2")

# Config via env
DEPLOY_CERT_SCRIPT = os.environ.get("DEPLOY_CERT_SCRIPT", "/opt/vps-deployment/deploy_app_with_certs.sh")
DEPLOY_SPA_SCRIPT  = os.environ.get("DEPLOY_SPA_SCRIPT",  "/opt/vps-deployment/deploy-spa-app.sh")
ADMIN_API_TOKEN    = os.environ.get("ADMIN_API_TOKEN")  # if set, API requires header X-ADMIN-TOKEN
DEFAULT_TIMEOUT    = int(os.environ.get("DEFAULT_TIMEOUT", "1800"))  # seconds
APPS_BASE          = os.environ.get("APPS_BASE", "/opt/vps-deployment/apps")

class DeployReq(BaseModel):
    repo_url: str
    domain: Optional[str] = None
    is_spa: Optional[bool] = False
    timeout_seconds: Optional[int] = None
    env: Optional[Dict[str, Any]] = Field(None, description="Optional mapping of environment variables to write into .env")

def require_admin(token_header: Optional[str]):
    if ADMIN_API_TOKEN:
        if not token_header or token_header != ADMIN_API_TOKEN:
            raise HTTPException(status_code=403, detail="invalid admin token")

def sanitize_app_name(repo_url: str) -> str:
    try:
        parsed = urlparse(repo_url)
        path = parsed.path or repo_url
    except Exception:
        path = repo_url
    base = os.path.basename(path)
    if base.endswith(".git"):
        base = base[:-4]
    if not base or "/" in base or "\\" in base or ".." in base:
        raise HTTPException(status_code=400, detail=f"cannot derive safe app name from repo_url: {repo_url}")
    return base

def dict_to_env_bytes(env: Dict[str, Any]) -> bytes:
    lines = []
    for k, v in env.items():
        if not isinstance(k, str) or k.strip() == "":
            continue
        s = "" if v is None else str(v)
        safe = s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
        lines.append(f'{k}="{safe}"')
    return ("\n".join(lines) + "\n").encode("utf-8")

def atomic_write(path: str, data: bytes, mode: int = 0o600):
    dirn = os.path.dirname(path)
    os.makedirs(dirn, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=dirn)
    try:
        with os.fdopen(fd, "wb") as fh:
            fh.write(data)
        os.replace(tmp, path)
        os.chmod(path, mode)
    finally:
        if os.path.exists(tmp):
            try:
                os.remove(tmp)
            except Exception:
                pass

def stream_script(script_path: str, args: list, timeout: int):
    """Exécute un script et yield ses logs en direct"""
    if not os.path.isfile(script_path) or not os.access(script_path, os.X_OK):
        yield f"ERROR: script not found or not executable: {script_path}\n"
        return

    cmd = [script_path] + args
    try:
        process = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        for line in process.stdout:
            yield line  # stream vers client HTTP
        process.wait(timeout=timeout)
        yield f"\n--- Process exited with code {process.returncode} ---\n"
    except subprocess.TimeoutExpired:
        process.kill()
        yield f"\n--- ERROR: script timeout after {timeout} seconds ---\n"

@app.get("/")
def root():
    return {"ok": True, "note": "Orchestrator - streaming logs enabled."}

@app.post("/deploy")
async def deploy(
    repo_url: str = Form(...),
    domain: str = Form(None),
    is_spa: bool = Form(False),
    env_file: UploadFile = File(None),
    x_admin_token: str = Header(None)
):
    require_admin(x_admin_token)

    env_dict = {}
    if env_file:
        contents = await env_file.read()
        env_dict = json.loads(contents.decode("utf-8"))

    if env_dict:
        env_bytes = dict_to_env_bytes(env_dict)
        env_path = os.path.join(APPS_BASE, ".env")
        atomic_write(env_path, env_bytes, mode=0o600)

    script = DEPLOY_SPA_SCRIPT if is_spa else DEPLOY_CERT_SCRIPT
    args = [repo_url]
    if domain:
        args.append(domain)

    return StreamingResponse(stream_script(script, args, DEFAULT_TIMEOUT), media_type="text/plain")
