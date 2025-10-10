#!/usr/bin/env groovy

/**
 * Airgap Pipeline Shared Library
 * 
 * This shared library contains common functions for airgap RKE2 pipeline operations.
 * It centralizes Docker execution, credential management, and artifact handling
 * to reduce code duplication between setup and destroy pipelines.
 */

// ========================================
// CONSTANTS AND CONFIGURATION
// ========================================

class AirgapPipelineConfig {
    static final String DEFAULT_RKE2_VERSION = 'v1.28.8+rke2r1'
    static final String DEFAULT_RANCHER_VERSION = 'v2.10-head'
    static final String DEFAULT_RANCHER_TEST_REPO = 'https://github.com/rancher/tests'
    static final String DEFAULT_QA_INFRA_REPO = 'https://github.com/rancher/qa-infra-automation'
    static final String DEFAULT_S3_BUCKET = 'jenkins-terraform-state-storage'
    static final String DEFAULT_S3_REGION = 'us-east-2'
    static final String DEFAULT_HOSTNAME_PREFIX = 'ansible-airgap'
    
    // Timeout values in minutes
    static final int TERRAFORM_TIMEOUT_MINUTES = 30
    static final int ANSIBLE_TIMEOUT_MINUTES = 45
    static final int VALIDATION_TIMEOUT_MINUTES = 15
    
    // File names
    static final String ANSIBLE_VARS_FILE = 'vars.yaml'
    static final String TERRAFORM_VARS_FILE = 'cluster.tfvars'
    static final String TERRAFORM_BACKEND_VARS_FILE = 'backend.tfvars'
    static final String ENVIRONMENT_FILE = '.env'
    
    // Docker configuration
    static final String DOCKER_BUILD_CONTEXT = '.'
    static final String DOCKERFILE_PATH = './tests/validation/Dockerfile.tofu.e2e'
    static final String SHARED_VOLUME_PREFIX = 'AnsibleAirgapSharedVolume'
    static final String CONTAINER_NAME_PREFIX = 'airgap-ansible'
    
    // Logging configuration
    static final String LOG_PREFIX_INFO = '[INFO]'
    static final String LOG_PREFIX_ERROR = '[ERROR]'
    static final String LOG_PREFIX_WARNING = '[WARNING]'
    static final String LOG_PREFIX_DEBUG = '[DEBUG]'
    
    // Slack configuration
    static final String SLACK_CHANNEL = '#rancher-qa'
    static final String SLACK_USERNAME = 'Jenkins'
    static final String SLACK_TITLE = 'Ansible Airgap Setup Pipeline'
}

// ========================================
// LOGGING UTILITY FUNCTIONS
// ========================================

def logInfo(msg) {
    echo "${AirgapPipelineConfig.LOG_PREFIX_INFO} ${getTimestamp()} ${msg}"
}

def logError(msg) {
    echo "${AirgapPipelineConfig.LOG_PREFIX_ERROR} ${getTimestamp()} ${msg}"
}

def logWarning(msg) {
    echo "${AirgapPipelineConfig.LOG_PREFIX_WARNING} ${getTimestamp()} ${msg}"
}

def logDebug(msg) {
    echo "${AirgapPipelineConfig.LOG_PREFIX_DEBUG} ${getTimestamp()} ${msg}"
}

def getTimestamp() {
    return new Date().format('yyyy-MM-dd HH:mm:ss')
}

// ========================================
// PARAMETER VALIDATION FUNCTIONS
// ========================================

def validateRKE2Version(version) {
    // RKE2 version format: v1.28.8+rke2r1
    return version ==~ /^v\d+\.\d+\.\d+\+rke2r\d+$/
}

def validateRancherVersion(version) {
    // Rancher version format: v2.10-head, v2.11.0, head
    return version ==~ /^(v\d+\.\d+(-head|\.\d+)?|head)$/
}

def validateRequiredVariables(requiredVars, env) {
    logInfo('Validating required environment variables')
    
    def missingVars = []
    requiredVars.each { varName ->
        def varValue = env."${varName}"
        if (!varValue || varValue.trim().isEmpty()) {
            missingVars.add(varName)
        }
    }
    
    if (!missingVars.isEmpty()) {
        def errorMsg = "Missing required environment variables: ${missingVars.join(', ')}"
        logError(errorMsg)
        error(errorMsg)
    }
    
    logInfo('All required variables validated successfully')
}

// ========================================
// CREDENTIAL MANAGEMENT FUNCTIONS
// ========================================

def getCommonCredentialsList() {
    return [
        string(credentialsId: 'AWS_ACCESS_KEY_ID', variable: 'AWS_ACCESS_KEY_ID'),
        string(credentialsId: 'AWS_SECRET_ACCESS_KEY', variable: 'AWS_SECRET_ACCESS_KEY'),
        string(credentialsId: 'AWS_SSH_PEM_KEY', variable: 'AWS_SSH_PEM_KEY'),
        string(credentialsId: 'AWS_SSH_KEY_NAME', variable: 'AWS_SSH_KEY_NAME'),
        string(credentialsId: 'SLACK_WEBHOOK', variable: 'SLACK_WEBHOOK')
    ]
}

def createCredentialEnvironmentFile(env) {
    // Create a temporary environment file with credentials
    def timestamp = System.currentTimeMillis()
    def credentialEnvFile = "docker-credentials-${timestamp}.env"
    
    def envContent = []
    
    // Add AWS credentials
    if (env.AWS_ACCESS_KEY_ID) {
        envContent.add("AWS_ACCESS_KEY_ID=${env.AWS_ACCESS_KEY_ID}")
    }
    if (env.AWS_SECRET_ACCESS_KEY) {
        envContent.add("AWS_SECRET_ACCESS_KEY=${env.AWS_SECRET_ACCESS_KEY}")
    }
    
    // Add SSH credentials
    if (env.AWS_SSH_PEM_KEY) {
        envContent.add("AWS_SSH_PEM_KEY=${env.AWS_SSH_PEM_KEY}")
    }
    if (env.AWS_SSH_KEY_NAME) {
        envContent.add("AWS_SSH_KEY_NAME=${env.AWS_SSH_KEY_NAME}")
    }
    
    // Add Slack webhook
    if (env.SLACK_WEBHOOK) {
        envContent.add("SLACK_WEBHOOK=${env.SLACK_WEBHOOK}")
    }
    
    // Add private registry password if available
    if (env.PRIVATE_REGISTRY_PASSWORD) {
        envContent.add("PRIVATE_REGISTRY_PASSWORD=${env.PRIVATE_REGISTRY_PASSWORD}")
    }
    
    // Write the environment file
    writeFile file: credentialEnvFile, text: envContent.join('\n')
    
    // Set secure permissions
    sh "chmod 600 ${credentialEnvFile}"
    
    logInfo("Created credential environment file: ${credentialEnvFile}")
    return credentialEnvFile
}

def addCredentialEnvFileToDockerCommand(dockerCmd, credentialEnvFile) {
    // Add credential environment file to Docker command without exposing credentials in logs
    def modifiedCmd = dockerCmd
    
    if (credentialEnvFile) {
        // Find the position where we should insert the credential environment file
        // This should be after the container name but before the image name
        def insertionPoint = modifiedCmd.lastIndexOf('--name')
        if (insertionPoint != -1) {
            // Find the end of the --name parameter
            def nameEndIndex = modifiedCmd.indexOf(' ', insertionPoint)
            if (nameEndIndex != -1) {
                // Find the next space after the container name
                def nextSpaceIndex = modifiedCmd.indexOf(' ', nameEndIndex + 1)
                if (nextSpaceIndex != -1) {
                    // Insert the credential environment file here
                    modifiedCmd = modifiedCmd.substring(0, nextSpaceIndex) +
                                 ' \\\n            --env-file ' + credentialEnvFile +
                                 modifiedCmd.substring(nextSpaceIndex)
                }
            }
        }
    }
    
    return modifiedCmd
}

// ========================================
// DOCKER MANAGEMENT FUNCTIONS
// ========================================

def buildDockerImage(imageName) {
    def resolvedImageName = imageName
    if (!resolvedImageName?.trim()) {
        resolvedImageName = "rancher-airgap-${getShortJobName()}-${env.BUILD_NUMBER ?: 'local'}"
        logWarning("Docker image name not provided, defaulting to ${resolvedImageName}")
    }

    logInfo("Building Docker image: ${resolvedImageName}")

    def candidateDockerfiles = [
        './tests/validation/Dockerfile.tofu.e2e',
        './validation/Dockerfile.tofu.e2e',
        './Dockerfile.tofu.e2e',
        './validation/Dockerfile.e2e',
        './tests/validation/Dockerfile.e2e'
    ]

    def dockerfilePath = candidateDockerfiles.find { fileExists(it) }

    if (!dockerfilePath) {
        def discovered = sh(script: "find . -maxdepth 5 -type f -name 'Dockerfile.tofu.e2e' -o -name 'Dockerfile.e2e'", returnStdout: true).trim()
        if (discovered) {
            dockerfilePath = discovered.readLines().first()
            logWarning("Using Dockerfile discovered via search: ${dockerfilePath}")
        } else {
            error("""Dockerfile not found.
Searched:
${candidateDockerfiles.collect { "  - ${it}" }.join('\n')}
Additionally searched workspace with 'find' but found no Dockerfile matching *tofu.e2e or *e2e.""")
        }
    }

    def dockerDir = dockerfilePath.contains('/') ? dockerfilePath.substring(0, dockerfilePath.lastIndexOf('/')) : '.'
    def configureScript = "${dockerDir}/configure.sh"
    if (!fileExists(configureScript)) {
        configureScript = './tests/validation/configure.sh'
        if (!fileExists(configureScript)) {
            configureScript = './validation/configure.sh'
        }
    }

    if (configureScript && fileExists(configureScript)) {
        sh "${configureScript} > /dev/null 2>&1"
    } else {
        logWarning("No configure.sh found next to ${dockerfilePath}; skipping configure step")
    }

    def buildDate = sh(script: "date -u '+%Y-%m-%dT%H:%M:%SZ'", returnStdout: true).trim()
    def vcsRefResult = sh(script: 'git rev-parse --short HEAD', returnStatus: true)
    def vcsRef = 'unknown'
    if (vcsRefResult == 0) {
        vcsRef = sh(script: 'git rev-parse --short HEAD', returnStdout: true).trim()
    } else {
        logWarning('Unable to determine git revision for Docker label (workspace is not a git repository)')
    }

    sh """
        docker build . \\
            -f ${dockerfilePath} \\
            -t ${resolvedImageName} \\
            --build-arg BUILD_DATE=${buildDate} \\
            --build-arg VCS_REF=${vcsRef} \\
            --label "pipeline.build.number=${env.BUILD_NUMBER}" \\
            --label "pipeline.job.name=${env.JOB_NAME}" \\
            --quiet
    """

    logInfo("Docker image built successfully using ${dockerfilePath}")
}

def createSharedVolume(volumeName) {
    logInfo("Creating shared volume: ${volumeName}")
    sh "docker volume create --name ${volumeName}"
}

def executeScriptInContainer(imageName, containerName, volumeName, scriptContent, extraEnv = [:], envFile = null) {
    def timestamp = System.currentTimeMillis()
    def actualContainerName = "${containerName}-script-${timestamp}"
    def scriptFile = "docker-script-${timestamp}.sh"
    def credentialEnvFile = null
    
    writeFile file: scriptFile, text: scriptContent
    
    try {
        def envVars = buildEnvironmentVariables(extraEnv)
        def dockerCmd = buildDockerCommand(imageName, actualContainerName, volumeName, scriptFile, envVars, envFile)
        
        // Execute Docker command with credentials and fallback strategy
        executeDockerCommandWithCredentials(dockerCmd, scriptFile, credentialEnvFile)
    } finally {
        // Cleanup script file
        sh "rm -f ${scriptFile}"
        
        // Cleanup credential environment file
        if (credentialEnvFile && fileExists(credentialEnvFile)) {
            sh "shred -vfz -n 3 ${credentialEnvFile} 2>/dev/null || rm -f ${credentialEnvFile}"
            logInfo("Credential environment file securely shredded")
        }
    }
}

private def buildEnvironmentVariables(extraEnv) {
    def envVars = ''
    extraEnv.each { key, value ->
        // Skip null/empty values to avoid passing literal "null" or blanks
        if (value != null) {
            def strVal = value.toString()
            if (strVal.trim()) {
                // Properly escape the value to prevent command injection
                def escapedValue = strVal.replace('"', '\\"').replace('$', '\\$')
                envVars += " -e \"${key}=${escapedValue}\""
            }
        }
    }
    return envVars
}

private def buildDockerCommand(imageName, containerName, volumeName, scriptFile, envVars, envFile) {
    // Escape container name to prevent issues
    def escapedContainerName = containerName.replaceAll('[^a-zA-Z0-9_-]', '_')
    
    // Build volume mounts with proper validation
    def volumeMounts = []
    
    // Add shared volume - check if Docker volume exists (not file system path)
    if (volumeName) {
        try {
            // Check if Docker volume exists
            def volumeCheck = sh(script: "docker volume inspect ${volumeName} >/dev/null 2>&1", returnStatus: true)
            if (volumeCheck == 0) {
                volumeMounts.add("-v \"${volumeName}:/root\"")
                logInfo("Shared volume ${volumeName} found and will be mounted")
            } else {
                logWarning("Docker volume ${volumeName} does not exist")
            }
        } catch (Exception e) {
            logWarning("Failed to check Docker volume ${volumeName}: ${e.message}")
        }
    }
    
    // Add qa-infra automation volume
    def qaInfraPath = "${pwd()}/qa-infra-automation"
    if (fileExists(qaInfraPath)) {
        volumeMounts.add("-v \"${qaInfraPath}:/root/go/src/github.com/rancher/qa-infra-automation\"")
    } else {
        logWarning("QA infra automation path not found: ${qaInfraPath}")
    }
    
    // Add script file volume
    if (fileExists(scriptFile)) {
        volumeMounts.add("-v \"${pwd()}/${scriptFile}:/tmp/script.sh\"")
    }
    
    // Add environment file volume
    if (envFile && fileExists(envFile)) {
        volumeMounts.add("-v \"${pwd()}/${envFile}:/tmp/.env\"")
    }
    
    def volumeMountStr = volumeMounts.join(' \\\n            ')
    
    // Construct the base command with proper escaping
    def baseCmd = """docker run --rm \\
            ${volumeMountStr} \\
            --name ${escapedContainerName} \\
            -e QA_INFRA_WORK_PATH=/root/go/src/github.com/rancher/qa-infra-automation \\
            ${envVars} \\
            "${imageName.trim()}\""""
    
    // Use a safer execution pattern
    def executionCmd = '''/bin/bash -c \'
        echo "=== DEBUG: Container started ==="
        echo "Current user: $(whoami)"
        echo "Current working directory: $(pwd)"
        echo "Environment file location: /tmp/.env"
        echo "Checking if /tmp/.env exists:"
        ls -la /tmp/.env || echo "FILE NOT FOUND"
        echo "Directory contents of /tmp:"
        ls -la /tmp/
        echo "=== END DEBUG ==="
        echo "Executing script: /tmp/script.sh"
        exec /bin/bash /tmp/script.sh
    \' '''
    
    return "${baseCmd} ${executionCmd}"
}

private def executeDockerCommandWithCredentials(dockerCmd, scriptFile, extraEnv = [:]) {
    def dockerSuccess = false
    def credentialEnvFile = null
    
    // Pre-execution validation
    validateDockerEnvironment()
    
    // Log the command for debugging (but mask sensitive data)
    logInfo('Executing Docker command (sensitive data masked):')
    logInfo(maskSensitiveData(dockerCmd))
    
    // Execute Docker command within withCredentials block to avoid interpolation
    withCredentials(getCommonCredentialsList()) {
        // Add PRIVATE_REGISTRY_PASSWORD from environment if available
        if (env.PRIVATE_REGISTRY_PASSWORD) {
            // This is already in the environment from parameters, no need to interpolate
        }
        
        // Create a temporary environment file with credentials
        credentialEnvFile = createCredentialEnvironmentFile(env)
        
        // Modify the Docker command to use the credential environment file
        def modifiedDockerCmd = addCredentialEnvFileToDockerCommand(dockerCmd, credentialEnvFile)
        
        // Approach 1: Try the primary command first (with environment file mounting)
        try {
            logInfo('Attempting Docker execution with environment file mounting...')
            
            // Add timeout and better error handling
            timeout(time: 30, unit: 'MINUTES') {
                sh modifiedDockerCmd
            }
            
            logInfo("✅ Docker command executed successfully with environment file mounting")
            dockerSuccess = true
        } catch (Exception primaryException) {
            logWarning("Primary Docker command failed: ${primaryException.message}")
            
            // Cleanup any dangling containers before fallback
            cleanupDanglingContainers()
            
            // Approach 2: Try fallback with direct environment variables
            try {
                logInfo('Attempting Docker execution with direct environment variables...')
                def fallbackCmd = buildFallbackDockerCommand(scriptFile, extraEnv)
                def modifiedFallbackCmd = addCredentialEnvFileToDockerCommand(fallbackCmd, credentialEnvFile)
                logInfo('Executing fallback docker command (sensitive data masked):')
                logInfo(maskSensitiveData(modifiedFallbackCmd))
                
                timeout(time: 30, unit: 'MINUTES') {
                    sh modifiedFallbackCmd
                }
                
                logInfo("✅ Fallback Docker command executed successfully with direct environment variables")
                dockerSuccess = true
            } catch (Exception fallbackException) {
                logError('All Docker execution approaches failed:')
                logError("  Primary (env file): ${primaryException.message}")
                logError("  Fallback (direct env): ${fallbackException.message}")
                
                // Additional diagnostic information
                provideDockerDiagnostics()
                
                throw fallbackException
            }
        }
    }
    
    if (!dockerSuccess) {
        error('All Docker execution attempts failed')
    }
}

private def buildFallbackDockerCommand(scriptFile, extraEnv = [:]) {
    // Similar to buildDockerCommand but for fallback scenario
    def directEnvVars = buildDirectEnvironmentVariables()
    def explicitEnvVars = buildEnvironmentVariables(extraEnv)
    
    // Build similar command structure as primary
    // This would need to be implemented based on the specific requirements
    // For now, return a simplified version
    return """
        docker run --rm \\
            -v ${env.VALIDATION_VOLUME}:/root \\
            -v ${pwd()}/${scriptFile}:/tmp/script.sh \\
            --name ${env.BUILD_CONTAINER_NAME}-fallback \\
            -e QA_INFRA_WORK_PATH=/root/go/src/github.com/rancher/qa-infra-automation \\
            -e TF_WORKSPACE="${env.TF_WORKSPACE}" \\
            -e TERRAFORM_VARS_FILENAME="${env.TERRAFORM_VARS_FILENAME}" \\
            ${directEnvVars} \\
            ${explicitEnvVars} \\
            "${env.IMAGE_NAME.trim()}" \\
            /bin/bash /tmp/script.sh
    """
}

private def buildDirectEnvironmentVariables() {
    def directEnvVars = ''
    def envFileExists = fileExists(env.ENV_FILE)
    
    if (envFileExists) {
        try {
            def fileContent = readFile file: env.ENV_FILE
            fileContent.split('\n').each { line ->
                line = line.trim()
                if (line && !line.startsWith('#') && line.contains('=')) {
                    def parts = line.split('=', 2)
                    if (parts.length == 2) {
                        def key = parts[0].trim()
                        def value = parts[1].trim()
                        // Pass only NON-SENSITIVE variables
                        // Sensitive variables will be passed via withCredentials block
                        if (key == 'AWS_REGION' ||
                            key == 'S3_BUCKET_NAME' || key == 'S3_REGION' || key == 'S3_KEY_PREFIX' ||
                            key == 'ANSIBLE_VARIABLES' || key == 'RKE2_VERSION' || key == 'RANCHER_VERSION' ||
                            key == 'HOSTNAME_PREFIX' ||
                            key == 'PRIVATE_REGISTRY_URL' || key == 'PRIVATE_REGISTRY_USERNAME' ||
                            key == 'RANCHER_HOSTNAME' ||
                            key == 'QA_INFRA_WORK_PATH' || key == 'TF_WORKSPACE' || key == 'TERRAFORM_VARS_FILENAME' ||
                            key == 'AWS_SSH_KEY_NAME') {
                            // Properly escape the value to prevent command injection
                            def escapedValue = value.replace('"', '\\"').replace('$', '\\$')
                            directEnvVars += " -e \"${key}=${escapedValue}\""
                        }
                    }
                }
            }
        } catch (Exception e) {
            logWarning("Could not read environment file for direct variable passing: ${e.message}")
        }
    }
    
    return directEnvVars
}

private def validateDockerEnvironment() {
    logInfo('Validating Docker environment...')
    
    try {
        // Check if Docker is installed and running
        def dockerVersion = sh(script: 'docker --version', returnStdout: true).trim()
        logInfo("Docker version: ${dockerVersion}")
        
        def dockerInfo = sh(script: 'docker info --format "Server Version: {{.ServerVersion}}"', returnStdout: true).trim()
        logInfo("Docker server info: ${dockerInfo}")
        
        // Check available disk space
        def diskSpace = sh(script: 'df -h /var/lib/docker 2>/dev/null || df -h /', returnStdout: true).trim()
        logInfo("Docker disk space: ${diskSpace}")
        
        logInfo('✅ Docker environment validation completed')
    } catch (Exception e) {
        error("❌ Docker environment validation failed: ${e.message}")
    }
}

private def cleanupDanglingContainers() {
    logInfo('Cleaning up any dangling containers...')
    
    try {
        // Remove any containers that might be stuck
        def containerPattern = env.BUILD_CONTAINER_NAME ?: 'build-container'
        
        sh """
            # Remove any containers that might be stuck
            docker ps -a --filter 'name=${containerPattern}' --format '{{.Names}}' | xargs -r docker rm -f 2>/dev/null || true
            
            # Remove any dangling containers older than 1 hour
            docker container prune --force --filter 'until=1h' 2>/dev/null || true
        """
        
        logInfo('✅ Container cleanup completed')
    } catch (Exception e) {
        logWarning("Container cleanup failed: ${e.message}")
    }
}

private def maskSensitiveData(command) {
    def maskedCommand = command
    
    // Mask AWS credentials - handle quoted values properly
    maskedCommand = maskedCommand.replaceAll(/-e "AWS_ACCESS_KEY_ID=[^"]+"/, '-e "AWS_ACCESS_KEY_ID=***"')
    maskedCommand = maskedCommand.replaceAll(/-e 'AWS_ACCESS_KEY_ID=[^']+'/, "-e 'AWS_ACCESS_KEY_ID=***'")
    maskedCommand = maskedCommand.replaceAll(/AWS_ACCESS_KEY_ID=[^\s]+/, 'AWS_ACCESS_KEY_ID=***')
    
    maskedCommand = maskedCommand.replaceAll(/-e "AWS_SECRET_ACCESS_KEY=[^"]+"/, '-e "AWS_SECRET_ACCESS_KEY=***"')
    maskedCommand = maskedCommand.replaceAll(/-e 'AWS_SECRET_ACCESS_KEY=[^']+'/, "-e 'AWS_SECRET_ACCESS_KEY=***'")
    maskedCommand = maskedCommand.replaceAll(/AWS_SECRET_ACCESS_KEY=[^\s]+/, 'AWS_SECRET_ACCESS_KEY=***')
    
    // Mask SSH credentials
    maskedCommand = maskedCommand.replaceAll(/-e "AWS_SSH_PEM_KEY=[^"]+"/, '-e "AWS_SSH_PEM_KEY=***"')
    maskedCommand = maskedCommand.replaceAll(/-e 'AWS_SSH_PEM_KEY=[^']+'/, "-e 'AWS_SSH_PEM_KEY=***'")
    maskedCommand = maskedCommand.replaceAll(/AWS_SSH_PEM_KEY=[^\s]+/, 'AWS_SSH_PEM_KEY=***')
    
    maskedCommand = maskedCommand.replaceAll(/-e "AWS_SSH_KEY_NAME=[^"]+"/, '-e "AWS_SSH_KEY_NAME=***"')
    maskedCommand = maskedCommand.replaceAll(/-e 'AWS_SSH_KEY_NAME=[^']+'/, "-e 'AWS_SSH_KEY_NAME=***'")
    maskedCommand = maskedCommand.replaceAll(/AWS_SSH_KEY_NAME=[^\s]+/, 'AWS_SSH_KEY_NAME=***')
    
    // Mask private registry credentials
    maskedCommand = maskedCommand.replaceAll(/-e "PRIVATE_REGISTRY_PASSWORD=[^"]+"/, '-e "PRIVATE_REGISTRY_PASSWORD=***"')
    maskedCommand = maskedCommand.replaceAll(/-e 'PRIVATE_REGISTRY_PASSWORD=[^']+'/, "-e 'PRIVATE_REGISTRY_PASSWORD=***'")
    maskedCommand = maskedCommand.replaceAll(/PRIVATE_REGISTRY_PASSWORD=[^\s]+/, 'PRIVATE_REGISTRY_PASSWORD=***')
    
    // Mask Slack webhook
    maskedCommand = maskedCommand.replaceAll(/-e "SLACK_WEBHOOK=[^"]+"/, '-e "SLACK_WEBHOOK=***"')
    maskedCommand = maskedCommand.replaceAll(/-e 'SLACK_WEBHOOK=[^']+'/, "-e 'SLACK_WEBHOOK=***'")
    maskedCommand = maskedCommand.replaceAll(/SLACK_WEBHOOK=[^\s]+/, 'SLACK_WEBHOOK=***')
    
    return maskedCommand
}

private def provideDockerDiagnostics() {
    logInfo('=== DOCKER DIAGNOSTICS ===')
    
    try {
        logInfo('Docker system information:')
        sh 'docker system df 2>/dev/null || echo "Docker system info not available"'
        
        logInfo('Docker container status:')
        def containerName = env.BUILD_CONTAINER_NAME ?: 'build-container'
        sh "docker ps -a --filter 'name=${containerName}' 2>/dev/null || echo 'No matching containers found'"
        
        logInfo('System resources:')
        sh 'free -h 2>/dev/null || echo "Memory info not available"'
        sh 'df -h 2>/dev/null | head -5 || echo "Disk info not available"'
        
    } catch (Exception e) {
        logWarning("Docker diagnostics failed: ${e.message}")
    }
    
    logInfo('=== END DOCKER DIAGNOSTICS ===')
}

// ========================================
// NOTIFICATION FUNCTIONS
// ========================================

def sendSlackNotification(config) {
    if (env.SLACK_WEBHOOK) {
        try {
            def payload = [
                channel: AirgapPipelineConfig.SLACK_CHANNEL,
                username: AirgapPipelineConfig.SLACK_USERNAME,
                color: config.color,
                title: AirgapPipelineConfig.SLACK_TITLE,
                message: config.message,
                fields: [
                    [title: 'Job', value: env.JOB_NAME, short: true],
                    [title: 'Build', value: env.BUILD_NUMBER, short: true],
                    [title: 'RKE2 Version', value: env.RKE2_VERSION, short: true],
                    [title: 'Rancher Version', value: env.RANCHER_VERSION, short: true]
                ]
            ]
            
            httpRequest(
                httpMode: 'POST',
                url: env.SLACK_WEBHOOK,
                contentType: 'APPLICATION_JSON',
                requestBody: groovy.json.JsonOutput.toJson(payload)
            )
            
            logInfo('Slack notification sent successfully')
        } catch (Exception e) {
            logError("Failed to send Slack notification: ${e.message}")
        }
    } else {
        logWarning('Slack webhook not configured - skipping notification')
    }
}

// ========================================
// UTILITY FUNCTIONS
// ========================================

def getShortJobName() {
    def jobName = "${env.JOB_NAME}"
    if (jobName.contains('/')) {
        def lastSlashIndex = jobName.lastIndexOf('/')
        return jobName.substring(lastSlashIndex + 1)
    }
    return jobName
}

def generateEnvironmentFile(env, excludeCredentials = true) {
    logInfo('Generating environment file for container execution')
    
    // Build environment content securely - EXCLUDE ALL sensitive credentials when requested
    def envLines = [
        '# Environment variables for infrastructure deployment containers',
        '# NOTE: All sensitive credentials are passed via Jenkins withCredentials block for security',
        "TF_WORKSPACE=${env.TF_WORKSPACE}",
        "BUILD_NUMBER=${env.BUILD_NUMBER}",
        "JOB_NAME=${env.JOB_NAME}",
        "TERRAFORM_TIMEOUT=${env.TERRAFORM_TIMEOUT ?: AirgapPipelineConfig.TERRAFORM_TIMEOUT_MINUTES}",
        "ANSIBLE_TIMEOUT=${env.ANSIBLE_TIMEOUT ?: AirgapPipelineConfig.ANSIBLE_TIMEOUT_MINUTES}",
        "QA_INFRA_WORK_PATH=${env.QA_INFRA_WORK_PATH}",
        "TERRAFORM_VARS_FILENAME=${env.TERRAFORM_VARS_FILENAME ?: AirgapPipelineConfig.TERRAFORM_VARS_FILE}",
        "ANSIBLE_VARS_FILENAME=${env.ANSIBLE_VARS_FILENAME ?: AirgapPipelineConfig.ANSIBLE_VARS_FILE}",
        "RKE2_VERSION=${env.RKE2_VERSION ?: AirgapPipelineConfig.DEFAULT_RKE2_VERSION}",
        "RANCHER_VERSION=${env.RANCHER_VERSION ?: AirgapPipelineConfig.DEFAULT_RANCHER_VERSION}",
        "HOSTNAME_PREFIX=${env.HOSTNAME_PREFIX ?: AirgapPipelineConfig.DEFAULT_HOSTNAME_PREFIX}",
        "RANCHER_HOSTNAME=${env.RANCHER_HOSTNAME}",
        "PRIVATE_REGISTRY_URL=${env.PRIVATE_REGISTRY_URL ?: ''}",
        "PRIVATE_REGISTRY_USERNAME=${env.PRIVATE_REGISTRY_USERNAME ?: 'default-user'}",
    ]
    
    if (!excludeCredentials) {
        envLines.addAll([
            '# PRIVATE_REGISTRY_PASSWORD included - WARNING: This is less secure than withCredentials',
            "PRIVATE_REGISTRY_PASSWORD=${env.PRIVATE_REGISTRY_PASSWORD ?: ''}",
            '',
            '# AWS Region Configuration',
            "AWS_REGION=${env.AWS_REGION ?: ''}",
            '',
            '# S3 Backend Configuration for OpenTofu',
            "S3_BUCKET_NAME=${env.S3_BUCKET_NAME ?: ''}",
            "S3_REGION=${env.S3_REGION ?: ''}",
            "S3_KEY_PREFIX=${env.S3_KEY_PREFIX ?: ''}",
            '',
            '# SSH key configuration - WARNING: This is less secure than withCredentials',
            "AWS_SSH_PEM_KEY=${env.AWS_SSH_PEM_KEY ?: ''}",
            "AWS_SSH_KEY_NAME=${env.AWS_SSH_KEY_NAME ?: ''}",
            '',
            '# Slack webhook - WARNING: This is less secure than withCredentials',
            "SLACK_WEBHOOK=${env.SLACK_WEBHOOK ?: ''}"
        ])
    } else {
        envLines.addAll([
            '# PRIVATE_REGISTRY_PASSWORD excluded - will be passed via withCredentials',
            '',
            '# AWS credentials excluded - will be passed via withCredentials',
            '# SLACK webhook excluded - will be passed via withCredentials'
        ])
    }
    
    def envContent = envLines.join('\n')
    def envFilePath = "${pwd()}/${env.ENV_FILE ?: AirgapPipelineConfig.ENVIRONMENT_FILE}"
    writeFile file: env.ENV_FILE ?: AirgapPipelineConfig.ENVIRONMENT_FILE, text: envContent
    logInfo("Environment file created: ${env.ENV_FILE ?: AirgapPipelineConfig.ENVIRONMENT_FILE}")
    
    return envFilePath
}

// ========================================
// CLEANUP FUNCTIONS
// ========================================

def cleanupContainersAndVolumes(buildContainerName, imageName, validationVolume) {
    logInfo('Cleaning up Docker containers and volumes')
    
    try {
        sh """
            # Stop and remove any containers with our naming pattern
            if docker ps -aq --filter "name=${buildContainerName}" | grep -q .; then
                docker ps -aq --filter "name=${buildContainerName}" | xargs -r docker stop || true
                docker ps -aq --filter "name=${buildContainerName}" | xargs -r docker rm -v || true
                echo "Stopped and removed containers for ${buildContainerName}"
            else
                echo "No containers found for ${buildContainerName}"
            fi
            
            # Remove the Docker image if it exists
            if docker images -q ${imageName} | grep -q .; then
                docker rmi -f ${imageName} || true
                echo "Removed Docker image ${imageName}"
            else
                echo "Docker image ${imageName} not found or already removed"
            fi
            
            # Remove the shared volume if it exists
            if docker volume ls -q | grep -q "^${validationVolume}\$"; then
                docker volume rm -f ${validationVolume} || true
                echo "Removed Docker volume ${validationVolume}"
            else
                echo "Docker volume ${validationVolume} not found or already removed"
            fi
            
            # Clean up any dangling images and volumes
            docker system prune -f || true
            echo "Docker cleanup completed"
        """
    } catch (Exception e) {
        logError("Docker cleanup failed: ${e.message}")
    }
}

return this