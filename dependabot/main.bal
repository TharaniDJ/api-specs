// Copyright (c) 2026, WSO2 LLC. (http://www.wso2.com).
//
// WSO2 LLC. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

import ballerina/file;
import ballerina/http;
import ballerina/io;
import ballerina/lang.regexp;
import ballerina/os;
import ballerinax/github;

// Repository record type
type Repository record {|
    string vendor;
    string api;
    string owner;
    string repo;
    string name;
    string lastVersion;
    string specPath;
    string releaseAssetName;
    string baseUrl;
    string documentationUrl;
    string description;
    string[] tags;
|};

// Update result record
type UpdateResult record {|
    Repository repo;
    string oldVersion;
    string newVersion;
    string apiVersion;
    string downloadUrl;
    string localPath;
|};

// Check for version updates
function hasVersionChanged(string oldVersion, string newVersion) returns boolean {
    return oldVersion != newVersion;
}

// Extract version from OpenAPI spec content
function extractApiVersion(string content) returns string|error {
    // Try to find "version:" under "info:" section
    // This is a simple regex-based extraction

    // Split content by lines
    string[] lines = regexp:split(re `\n`, content);
    boolean inInfoSection = false;

    foreach string line in lines {
        string trimmedLine = line.trim();

        // Check if we're entering info section
        if trimmedLine == "info:" {
            inInfoSection = true;
            continue;
        }

        // If we're in info section, look for version
        if inInfoSection {
            // Exit info section if we hit another top-level key
            if !line.startsWith(" ") && !line.startsWith("\t") && trimmedLine != "" && !trimmedLine.startsWith("#") {
                break;
            }

            // Look for version field
            if trimmedLine.startsWith("version:") {
                // Extract version value
                string[] parts = regexp:split(re `:`, trimmedLine);
                if parts.length() >= 2 {
                    string versionValue = parts[1].trim();
                    // Remove quotes if present
                    versionValue = removeQuotes(versionValue);
                    return versionValue;
                }
            }
        }
    }

    return error("Could not extract API version from spec");
}

// Extract release asset download URL
isolated function downloadFromGitHubReleaseTag(github:Client githubClient, string owner,
        string repo, string assetName, string tagName) returns string? {
    github:Release|error release = githubClient->/repos/[owner]/[repo]/releases/tags/[tagName]();

    if release is error {
        return ();
    }

    github:ReleaseAsset[]? assets = release.assets;
    if assets is github:ReleaseAsset[] {
        foreach github:ReleaseAsset asset in assets {
            if asset.name == assetName {
                print(string `Found in release assets`, "Info", 2);
                return asset.browser_download_url;
            }
        }
    }
    return ();
}

// Get raw GitHub URL for spec
isolated function downloadFromGitHubRawLink(string owner, string repo,
        string tagName, string specPath) returns string {
    print(string `Not in release assets, downloading from repository...`, "Info", 2);
    return string `https://raw.githubusercontent.com/${owner}/${repo}/${tagName}/${specPath}`;
}

// Download OpenAPI spec from release asset or repo
function downloadSpec(github:Client githubClient, string owner, string repo,
        string assetName, string tagName, string specPath) returns string|error {

    print(string `Downloading ${assetName}...`, "Info", 2);

    // Try to get from release assets first
    string? assetUrl = downloadFromGitHubReleaseTag(githubClient, owner, repo, assetName, tagName);

    string downloadUrl;
    // If not found in assets, try direct download from repo
    if assetUrl is () {
        downloadUrl = downloadFromGitHubRawLink(owner, repo, tagName, specPath);
    } else {
        downloadUrl = assetUrl;
    }

    // Download the file
    http:Client httpClient = check new (downloadUrl);
    http:Response response = check httpClient->get("");

    if response.statusCode != 200 {
        return error(string `Failed to download: HTTP ${response.statusCode} from ${downloadUrl}`);
    }

    // Get content
    string|byte[] content = check response.getTextPayload();

    return content is string ? content : string:fromBytes(content);
}

// Save spec to file
function saveSpec(string content, string localPath) returns error? {
    // Create directory if it doesn't exist
    string dirPath = check file:parentPath(localPath);
    if !check file:test(dirPath, file:EXISTS) {
        check file:createDir(dirPath, file:RECURSIVE);
    }

    // Write content to file
    check io:fileWriteString(localPath, content);
    print(string `Saved to ${localPath}`, "Info", 2);
    return;
}

// Create metadata.json file
function createMetadataFile(Repository repo, string version, string dirPath) returns error? {
    json metadata = {
        "name": repo.name,
        "baseUrl": repo.baseUrl,
        "documentationUrl": repo.documentationUrl,
        "description": repo.description,
        "tags": repo.tags
    };

    string metadataPath = string `${dirPath}/.metadata.json`;
    check io:fileWriteJson(metadataPath, metadata);
    print(string `Created metadata at ${metadataPath}`, "Info", 2);
    return;
}

// Remove quotes from string
function removeQuotes(string s) returns string {
    return re `["']`.replace(s, "");
}

// Utility function to print logs with indentation
isolated function print(string message, string level, int indentation) {
    string spaces = string:'join("", from int i in 0 ..< indentation select " ");
    io:println(string `${spaces}${level} ${message}`);
}

// Process a single repository release
function processRelease(github:Client githubClient, Repository repo, github:Release latestRelease,
        UpdateResult[] updates) returns error? {
    string tagName = latestRelease.tag_name;
    string? publishedAt = latestRelease.published_at;
    boolean isDraft = latestRelease.draft;
    boolean isPrerelease = latestRelease.prerelease;

    if isPrerelease || isDraft {
        print(string `Skipping pre-release: ${tagName}`, "Info", 2);
        return;
    }

    print(string `Latest release tag: ${tagName}`, "Info", 2);
    if publishedAt is string {
        print(string `Published: ${publishedAt}`, "Info", 2);
    }

    if !hasVersionChanged(repo.lastVersion, tagName) {
        print(string `No updates`, "Info", 2);
        return;
    }

    print("UPDATE AVAILABLE!", "Info", 2);
    check handleUpdate(githubClient, repo, tagName, updates);
}

// Handle repository update
function handleUpdate(github:Client githubClient, Repository repo, string tagName,
        UpdateResult[] updates) returns error? {
    // Download the spec to extract version
    string|error specContent = downloadSpec(
            githubClient,
            repo.owner,
            repo.repo,
            repo.releaseAssetName,
            tagName,
            repo.specPath
    );

    if specContent is error {
        print("Download failed: " + specContent.message(), "Info", 2);
        return;
    }

    // Extract API version from spec
    string apiVersion = check extractVersionFromSpec(specContent, tagName);

    // Structure: openapi/{vendor}/{api}/{apiVersion}/
    string versionDir = "../openapi/" + repo.vendor + "/" + repo.api + "/" + apiVersion;
    string localPath = versionDir + "/openapi.yaml";

    // Save the spec
    check saveSpec(specContent, localPath);

    // Create metadata.json
    check createMetadataFile(repo, apiVersion, versionDir);

    // Track the update
    updates.push({
        repo: repo,
        oldVersion: repo.lastVersion,
        newVersion: tagName,
        apiVersion: apiVersion,
        downloadUrl: "https://github.com/" + repo.owner + "/" + repo.repo + "/releases/tag/" + tagName,
        localPath: localPath
    });

    // Update the repo record
    repo.lastVersion = tagName;
}

// Extract version from spec with fallback
function extractVersionFromSpec(string specContent, string tagName) returns string|error {
    var apiVersionResult = extractApiVersion(specContent);
    if apiVersionResult is error {
        print("Could not extract API version, using tag: " + tagName, "Info", 2);
        // Fall back to tag name (remove 'v' prefix if exists)
        return tagName.startsWith("v") ? tagName.substring(1) : tagName;
    }
    print("API Version: " + apiVersionResult, "Info", 2);
    return apiVersionResult;
}

// Main monitoring function
public function main() returns error? {
    io:println("=== Dependabot OpenAPI Monitor ===");
    io:println("Starting OpenAPI specification monitoring...\n");

    // Get GitHub token
    string? token = os:getEnv("GH_TOKEN");
    if token is () {
        token = os:getEnv("packagePAT");
    }
    if token is () {
        token = os:getEnv("BALLERINA_BOT_TOKEN");
    }
    if token is () {
        io:println("Error: GH_TOKEN, packagePAT, or BALLERINA_BOT_TOKEN environment variable not set");
        io:println("Please set one of these environment variables before running this program.");
        return;
    }

    // Initialize GitHub client
    github:Client githubClient = check new ({
        auth: {
            token
        }
    });

    // Load repositories from repos.json
    json reposJson = check io:fileReadJson("../repos.json");
    Repository[] repos = check reposJson.cloneWithType();

    io:println(string `Found ${repos.length()} repositories to monitor.\n`);

    // Track updates
    UpdateResult[] updates = [];

    // Check each repository
    foreach Repository repo in repos {
        io:println(string `Checking: ${repo.name} (${repo.vendor}/${repo.api})`);

        // Get latest release
        github:Release|error latestRelease = githubClient->/repos/[repo.owner]/[repo.repo]/releases/latest();

        if latestRelease is github:Release {
            error? result = processRelease(githubClient, repo, latestRelease, updates);
            if result is error {
                print("Processing failed: " + result.message(), "Info", 2);
            }
        } else {
            string errorMsg = latestRelease.message();
            if errorMsg.includes("404") {
                print(string `Error: No releases found for ${repo.owner}/${repo.repo}`, "Info", 2);
            } else if errorMsg.includes("401") || errorMsg.includes("403") {
                print(string `Error: Authentication failed`, "Info", 2);
            } else {
                print(string `Error: ${errorMsg}`, "Info", 2);
            }
        }

        io:println("");
    }

    // Report updates
    if updates.length() > 0 {
        io:println(string `\nFound ${updates.length()} updates:\n`);

        // Create update summary
        string[] updateSummary = [];
        foreach UpdateResult update in updates {
            string summary = string `- ${update.repo.vendor}/${update.repo.api}: ${update.oldVersion} → ${update.newVersion} (API v${update.apiVersion})`;
            io:println(summary);
            updateSummary.push(summary);
        }

        // Update repos.json
        check io:fileWriteJson("../repos.json", repos.toJson());
        io:println("\nUpdated repos.json with new versions");

        // Write update summary for the workflow to use
        string summaryContent = string:'join("\n", ...updateSummary);
        check io:fileWriteString("../UPDATE_SUMMARY.txt", summaryContent);
        io:println("Created UPDATE_SUMMARY.txt for workflow");

        io:println("\nUpdate detection complete. GitHub Actions workflow will handle PR creation.");

    } else {
        io:println("All specifications are up-to-date!");
    }
}
