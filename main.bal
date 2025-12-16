import ballerina/io;
import ballerina/os;
import ballerina/http;
import ballerina/file;
import ballerinax/github;

// Repository record type
type Repository record {|
    string owner;
    string repo;
    string name;
    string lastVersion;
    string lastChecked;
    string specPath;
    string releaseAssetName;
|};

// Update result record
type UpdateResult record {|
    Repository repo;
    string oldVersion;
    string newVersion;
    string downloadUrl;
    string localPath;
|};

// Check for version updates
function hasVersionChanged(string oldVersion, string newVersion) returns boolean {
    return oldVersion != newVersion;
}

// Download OpenAPI spec from release asset or repo
function downloadSpec(github:Client githubClient, string owner, string repo, 
                     string assetName, string tagName, string localPath, string specPath) returns error? {
    
    io:println(string `  📥 Downloading ${assetName}...`);
    
    string? downloadUrl = ();
    
    // Try to get from release assets first
    github:Release|error release = githubClient->/repos/[owner]/[repo]/releases/tags/[tagName]();
    
    if release is github:Release {
        github:ReleaseAsset[]? assets = release.assets;
        if assets is github:ReleaseAsset[] {
            foreach github:ReleaseAsset asset in assets {
                if asset.name == assetName {
                    downloadUrl = asset.browser_download_url;
                    io:println(string `  ✅ Found in release assets`);
                    break;
                }
            }
        }
    }
    
    // If not found in assets, try direct download from repo
    if downloadUrl is () {
        io:println(string `  ℹ️  Not in release assets, downloading from repository...`);
        // Use the specPath from repos.json
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
    
    // Create directory if it doesn't exist
    string dirPath = check file:parentPath(localPath);
    if !check file:test(dirPath, file:EXISTS) {
        check file:createDir(dirPath, file:RECURSIVE);
    }
    
    // Write to file
    if content is string {
        check io:fileWriteString(localPath, content);
    } else if content is byte[] {
        check io:fileWriteBytes(localPath, content);
    } else {
        return error("Failed to get content from response");
    }
    
    io:println(string `  ✅ Downloaded to ${localPath}`);
    return;
}

// Main monitoring function
public function main() returns error? {
    io:println("=== Dependabot OpenAPI Monitor ===");
    io:println("Starting OpenAPI specification monitoring...\n");
    
    // Get GitHub token
    string? token = os:getEnv("GH_TOKEN");
    if token is () {
        io:println("❌ Error: GH_TOKEN environment variable not set");
        io:println("Please set the GH_TOKEN environment variable before running this program.");
        return;
    }
    
    string tokenValue = <string>token;
    
    // Validate token
    if tokenValue.length() == 0 {
        io:println("❌ Error: GH_TOKEN is empty!");
        return;
    }
    
    io:println(string `🔍 Token loaded (length: ${tokenValue.length()})`);
    
    // Initialize GitHub client
    github:Client githubClient = check new ({
        auth: {
            token: tokenValue
        }
    });
    
    // Load repositories from repos.json
    json reposJson = check io:fileReadJson("repos.json");
    Repository[] repos = check reposJson.cloneWithType();
    
    io:println(string `Found ${repos.length()} repositories to monitor.\n`);
    
    // Track updates
    UpdateResult[] updates = [];
    
    // Check each repository
    foreach Repository repo in repos {
        io:println(string `Checking: ${repo.name} (${repo.owner}/${repo.repo})`);
        
        // Get latest release
        github:Release|error latestRelease = githubClient->/repos/[repo.owner]/[repo.repo]/releases/latest();
        
        if latestRelease is github:Release {
            string tagName = latestRelease.tag_name;
            string? publishedAt = latestRelease.published_at;
            boolean isDraft = latestRelease.draft;
            boolean isPrerelease = latestRelease.prerelease;
            
            if isPrerelease || isDraft {
                io:println(string `  ⏭️  Skipping pre-release: ${tagName}`);
            } else {
                io:println(string `  Latest version: ${tagName}`);
                if publishedAt is string {
                    io:println(string `  Published: ${publishedAt}`);
                }
                
                if hasVersionChanged(repo.lastVersion, tagName) {
                    io:println(string `  ✅ UPDATE AVAILABLE!`);
                    
                    // Define local path for the spec
                    string localPath = string `specs/${repo.owner}/${repo.repo}/${repo.releaseAssetName}`;
                    
                    // Download the spec
                    error? downloadResult = downloadSpec(
                        githubClient, 
                        repo.owner, 
                        repo.repo, 
                        repo.releaseAssetName, 
                        tagName, 
                        localPath,
                        repo.specPath
                    );
                    
                    if downloadResult is error {
                        io:println(string `  ❌ Download failed: ${downloadResult.message()}`);
                    } else {
                        // Track the update
                        updates.push({
                            repo: repo,
                            oldVersion: repo.lastVersion,
                            newVersion: tagName,
                            downloadUrl: string `https://github.com/${repo.owner}/${repo.repo}/releases/tag/${tagName}`,
                            localPath: localPath
                        });
                        
                        // Update the repo record
                        repo.lastVersion = tagName;
                    }
                } else {
                    io:println(string `  ℹ️  No updates`);
                }
            }
        } else {
            string errorMsg = latestRelease.message();
            if errorMsg.includes("404") {
                io:println(string `  ❌ Error: No releases found for ${repo.owner}/${repo.repo}`);
            } else if errorMsg.includes("401") || errorMsg.includes("403") {
                io:println(string `  ❌ Error: Authentication failed`);
            } else {
                io:println(string `  ❌ Error: ${errorMsg}`);
            }
        }
        
        io:println("");
    }
    
    // Report updates
    if updates.length() > 0 {
        io:println(string `\n🎉 Found ${updates.length()} updates:\n`);
        
        // Create update summary
        string[] updateSummary = [];
        foreach UpdateResult update in updates {
            string summary = string `- ${update.repo.name}: ${update.oldVersion} → ${update.newVersion}`;
            io:println(summary);
            updateSummary.push(summary);
        }
        
        // Update repos.json
        check io:fileWriteJson("repos.json", repos.toJson());
        io:println("\n✅ Updated repos.json with new versions");
        
        // Write update summary for shell script to use
        string summaryContent = string:'join("\n", ...updateSummary);
        check io:fileWriteString("UPDATE_SUMMARY.txt", summaryContent);
        
        io:println("\n📌 Next steps:");
        io:println("1. Run the shell script to create a PR");
        io:println("2. ./scripts/create-pr.sh");
        
    } else {
        io:println("✨ All specifications are up-to-date!");
    }
}