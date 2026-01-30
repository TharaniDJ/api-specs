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
import ballerina/io;
import ballerina/os;
import ballerina/http;
import ballerina/file;
import ballerina/lang.regexp;
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

// Download OpenAPI spec from release asset or repo
function downloadSpec(github:Client githubClient, string owner, string repo, 
                     string assetName, string tagName, string specPath) returns string|error {
    
    io:println(string `  Downloading ${assetName}...`);
    
    string? downloadUrl = ();
    
    // Try to get from release assets first
    github:Release|error release = githubClient->/repos/[owner]/[repo]/releases/tags/[tagName]();
    
    if release is github:Release {
        github:ReleaseAsset[]? assets = release.assets;
        if assets is github:ReleaseAsset[] {
            foreach github:ReleaseAsset asset in assets {
                if asset.name == assetName {
                    downloadUrl = asset.browser_download_url;
                    io:println(string `  Found in release assets`);
                    break;
                }
            }
        }
    }
    
    // If not found in assets, try direct download from repo
    if downloadUrl is () {
        io:println(string `  Not in release assets, downloading from repository...`);
        downloadUrl = string `https://raw.githubusercontent.com/${owner}/${repo}/${tagName}/${specPath}`;
    }
    
    // Download the file
    http:Client httpClient = check new (<string>downloadUrl);
    http:Response response = check httpClient->get("");
    
    if response.statusCode != 200 {
        return error(string `Failed to download: HTTP ${response.statusCode} from ${<string>downloadUrl}`);
    }
    
    // Get content
    string|byte[]|error content = response.getTextPayload();
    
    if content is error {
        return error("Failed to get content from response");
    }
    
    string textContent;
    if content is string {
        textContent = content;
    } else {
        // Convert bytes to string
        textContent = check string:fromBytes(content);
    }
    
    io:println(string `  Downloaded spec`);
    return textContent;
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
    io:println(string `  Saved to ${localPath}`);
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
    io:println(string `  Created metadata at ${metadataPath}`);
    return;
}

// Remove quotes from string
function removeQuotes(string s) returns string {
    string result = "";
    foreach int i in 0 ..< s.length() {
        string c = s.substring(i, i + 1);
        if c != "\"" && c != "'" {
            result += c;
        }
    }
    return result;
}

// Main monitoring function
public function main() returns error? {
    io:println("=== Dependabot OpenAPI Monitor ===");
    io:println("Starting OpenAPI specification monitoring...\n");
    
    // Get GitHub token
    string? token = os:getEnv("GH_TOKEN");
    if token is () {
        io:println("Error: GH_TOKEN environment variable not set");
        io:println("Please set the GH_TOKEN environment variable before running this program.");
        return;
    }
    
    string tokenValue = <string>token;
    
    // Validate token
    if tokenValue.length() == 0 {
        io:println("Error: GH_TOKEN is empty!");
        return;
    }
    
    io:println(string `Token loaded (length: ${tokenValue.length()})`);
    
    // Initialize GitHub client
    github:Client githubClient = check new ({
        auth: {
            token: tokenValue
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
            string tagName = latestRelease.tag_name;
            string? publishedAt = latestRelease.published_at;
            boolean isDraft = latestRelease.draft;
            boolean isPrerelease = latestRelease.prerelease;
            
            if isPrerelease || isDraft {
                io:println(string `  Skipping pre-release: ${tagName}`);
            } else {
                io:println(string `  Latest release tag: ${tagName}`);
                if publishedAt is string {
                    io:println(string `  Published: ${publishedAt}`);
                }
                
                if hasVersionChanged(repo.lastVersion, tagName) {
                    io:println("  UPDATE AVAILABLE!");
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
                        io:println("  Download failed: " + specContent.message());
                    } else {
                        // Extract API version from spec
                        string apiVersion = "";
                        var apiVersionResult = extractApiVersion(specContent);
                        if apiVersionResult is error {
                            io:println("  Could not extract API version, using tag: " + tagName);
                            // Fall back to tag name (remove 'v' prefix if exists)
                            apiVersion = tagName.startsWith("v") ? tagName.substring(1) : tagName;
                        } else {
                            apiVersion = apiVersionResult;
                            io:println("  API Version: " + apiVersion);
                        }
                        // Structure: openapi/{vendor}/{api}/{apiVersion}/
                        string versionDir = "../openapi/" + repo.vendor + "/" + repo.api + "/" + apiVersion;
                        string localPath = versionDir + "/openapi.yaml";
                        // Save the spec
                        error? saveResult = saveSpec(specContent, localPath);
                        if saveResult is error {
                            io:println("  Save failed: " + saveResult.message());
                        } else {
                            // Create metadata.json
                            error? metadataResult = createMetadataFile(repo, apiVersion, versionDir);
                            if metadataResult is error {
                                io:println("  Metadata creation failed: " + metadataResult.message());
                            }
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
                    }
                } else {
                    io:println(string `  No updates`);
                }
            }
        } else {
            string errorMsg = latestRelease.message();
            if errorMsg.includes("404") {
                io:println(string `  Error: No releases found for ${repo.owner}/${repo.repo}`);
            } else if errorMsg.includes("401") || errorMsg.includes("403") {
                io:println(string `  Error: Authentication failed`);
            } else {
                io:println(string `  Error: ${errorMsg}`);
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
