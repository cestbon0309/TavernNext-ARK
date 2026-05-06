#include "napi/native_api.h"

#include <git2.h>

#include <atomic>
#include <cctype>
#include <cstring>
#include <memory>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

std::atomic_bool g_gitInitialized(false);

struct GitBranchInfo {
    std::string name;
    std::string commit;
    bool current { false };
    std::string label;
};

struct GitUpdateLikeResult {
    std::string shortCommitHash;
    std::string currentCommitHash;
    std::string currentBranchName;
    std::string extensionPath;
    bool isUpToDate { true };
    std::string remoteUrl;
};

enum class GitTaskKind {
    Clone,
    Rehydrate,
    Update,
    Version,
    Branches,
    SwitchBranch,
};

struct GitTask {
    napi_env env { nullptr };
    napi_async_work work { nullptr };
    napi_deferred deferred { nullptr };
    GitTaskKind kind { GitTaskKind::Clone };
    std::string url;
    std::string path;
    std::string branch;
    std::string commit;
    std::string caBundlePath;
    int depth { 0 };
    bool unshallow { false };
    bool allowInsecureCertificate { false };
    bool ok { false };
    std::string error;
    std::string stringResult;
    GitUpdateLikeResult updateResult;
    std::vector<GitBranchInfo> branchesResult;
};

std::string LastGitError(const std::string &fallback)
{
    const git_error *error = git_error_last();
    if (error != nullptr && error->message != nullptr && std::strlen(error->message) > 0) {
        return error->message;
    }
    return fallback;
}

int CheckGit(int rc, const std::string &message)
{
    if (rc < 0) {
        throw std::runtime_error(message + ": " + LastGitError("unknown libgit2 error"));
    }
    return rc;
}

void EnsureGitInitialized()
{
    bool expected = false;
    if (g_gitInitialized.compare_exchange_strong(expected, true)) {
        git_libgit2_init();
    }
}

int AllowCertificate(git_cert *, int, const char *, void *)
{
    return 0;
}

void ApplyCommonFetchOptions(git_fetch_options &fetchOpts, const GitTask &task)
{
    fetchOpts.callbacks.certificate_check = task.allowInsecureCertificate ? AllowCertificate : nullptr;
    if (task.unshallow) {
        fetchOpts.depth = GIT_FETCH_DEPTH_UNSHALLOW;
    } else if (task.depth > 0) {
        fetchOpts.depth = task.depth;
    }
    fetchOpts.prune = GIT_FETCH_PRUNE;
}

void ApplyCertLocation(const GitTask &task)
{
    if (!task.caBundlePath.empty()) {
        CheckGit(git_libgit2_opts(GIT_OPT_SET_SSL_CERT_LOCATIONS, task.caBundlePath.c_str(), nullptr),
            "Unable to set Git TLS certificate bundle");
    }
}

std::string OidToString(const git_oid *oid)
{
    char buffer[GIT_OID_HEXSZ + 1] = { 0 };
    git_oid_tostr(buffer, sizeof(buffer), oid);
    return std::string(buffer);
}

std::string ShortOid(const std::string &oid)
{
    return oid.size() > 7 ? oid.substr(0, 7) : oid;
}

std::string Trim(const std::string &value)
{
    size_t start = 0;
    while (start < value.size() && std::isspace(static_cast<unsigned char>(value[start])) != 0) {
        ++start;
    }

    size_t end = value.size();
    while (end > start && std::isspace(static_cast<unsigned char>(value[end - 1])) != 0) {
        --end;
    }

    return value.substr(start, end - start);
}

bool IsFullOid(const std::string &value)
{
    if (value.size() != GIT_OID_HEXSZ) {
        return false;
    }

    for (char ch : value) {
        if (std::isxdigit(static_cast<unsigned char>(ch)) == 0) {
            return false;
        }
    }

    return true;
}

std::string NormalizeBranchReference(const std::string &reference)
{
    std::string branch = Trim(reference);
    if (branch.empty() || IsFullOid(branch)) {
        return "";
    }

    const std::string refsHeads = "refs/heads/";
    const std::string originPrefix = "origin/";
    if (branch.rfind(refsHeads, 0) == 0) {
        branch = branch.substr(refsHeads.size());
    } else if (branch.rfind(originPrefix, 0) == 0) {
        branch = branch.substr(originPrefix.size());
    } else if (branch.rfind("refs/tags/", 0) == 0 || branch.rfind("refs/", 0) == 0) {
        return "";
    }

    std::string refName = "refs/heads/" + branch;
    if (git_reference_is_valid_name(refName.c_str()) == 0) {
        return "";
    }

    return branch;
}

std::string CurrentCommit(git_repository *repo)
{
    git_oid oid;
    CheckGit(git_reference_name_to_id(&oid, repo, "HEAD"), "Unable to resolve HEAD");
    return OidToString(&oid);
}

std::string CurrentBranch(git_repository *repo)
{
    git_reference *head = nullptr;
    if (git_repository_head(&head, repo) < 0) {
        return "";
    }

    const char *name = git_reference_shorthand(head);
    std::string result = name == nullptr ? "" : name;
    git_reference_free(head);
    return result;
}

std::string RemoteUrl(git_repository *repo)
{
    git_remote *remote = nullptr;
    if (git_remote_lookup(&remote, repo, "origin") < 0) {
        return "";
    }

    const char *url = git_remote_url(remote);
    std::string result = url == nullptr ? "" : url;
    git_remote_free(remote);
    return result;
}

bool HasRemote(git_repository *repo)
{
    git_remote *remote = nullptr;
    int rc = git_remote_lookup(&remote, repo, "origin");
    if (remote != nullptr) {
        git_remote_free(remote);
    }
    return rc == 0;
}

void EnsureOriginRemote(git_repository *repo, const std::string &url)
{
    git_remote *remote = nullptr;
    int rc = git_remote_lookup(&remote, repo, "origin");
    if (rc == GIT_ENOTFOUND) {
        rc = git_remote_create(&remote, repo, "origin", url.c_str());
        if (remote != nullptr) {
            git_remote_free(remote);
        }
        CheckGit(rc, "Unable to create origin remote");
        return;
    }

    if (remote != nullptr) {
        git_remote_free(remote);
    }
    CheckGit(rc, "Unable to inspect origin remote");
    CheckGit(git_remote_set_url(repo, "origin", url.c_str()), "Unable to update origin remote URL");
}

void FetchOrigin(git_repository *repo, const GitTask &task, bool unshallow)
{
    git_remote *remote = nullptr;
    CheckGit(git_remote_lookup(&remote, repo, "origin"), "Unable to find origin remote");

    git_fetch_options fetchOpts = GIT_FETCH_OPTIONS_INIT;
    GitTask adjustedTask = task;
    adjustedTask.unshallow = unshallow;
    ApplyCommonFetchOptions(fetchOpts, adjustedTask);
    int rc = git_remote_fetch(remote, nullptr, &fetchOpts, nullptr);
    git_remote_free(remote);
    CheckGit(rc, "Unable to fetch origin");
}

void EnsureAllOriginBranchesRefspec(git_repository *repo)
{
    git_remote *remote = nullptr;
    if (git_remote_lookup(&remote, repo, "origin") < 0) {
        return;
    }

    const std::string allBranches = "+refs/heads/*:refs/remotes/origin/*";
    bool hasAllBranches = false;
    git_strarray refspecs = { nullptr, 0 };
    if (git_remote_get_fetch_refspecs(&refspecs, remote) == 0) {
        for (size_t i = 0; i < refspecs.count; ++i) {
            if (refspecs.strings[i] != nullptr && allBranches == refspecs.strings[i]) {
                hasAllBranches = true;
                break;
            }
        }
    }
    git_strarray_free(&refspecs);
    git_remote_free(remote);

    if (!hasAllBranches) {
        int rc = git_remote_add_fetch(repo, "origin", allBranches.c_str());
        if (rc < 0 && rc != GIT_EEXISTS) {
            CheckGit(rc, "Unable to configure origin branch refspec");
        }
    }
}

bool IsHeadUpToDateWithUpstream(git_repository *repo, const std::string &branch)
{
    if (branch.empty()) {
        return true;
    }

    std::string upstreamName = "refs/remotes/origin/" + branch;
    git_oid localOid;
    git_oid upstreamOid;
    if (git_reference_name_to_id(&localOid, repo, "HEAD") < 0) {
        return true;
    }
    if (git_reference_name_to_id(&upstreamOid, repo, upstreamName.c_str()) < 0) {
        return true;
    }

    return git_oid_equal(&localOid, &upstreamOid) != 0;
}

struct RepositoryStatus {
    bool indexDirty { false };
    bool workdirDirty { false };
    bool conflicted { false };
};

int AccumulateStatus(const char *, unsigned int statusFlags, void *payload)
{
    auto *summary = static_cast<RepositoryStatus *>(payload);
    const unsigned int indexFlags = GIT_STATUS_INDEX_NEW | GIT_STATUS_INDEX_MODIFIED | GIT_STATUS_INDEX_DELETED |
        GIT_STATUS_INDEX_RENAMED | GIT_STATUS_INDEX_TYPECHANGE;
    const unsigned int workdirFlags = GIT_STATUS_WT_NEW | GIT_STATUS_WT_MODIFIED | GIT_STATUS_WT_DELETED |
        GIT_STATUS_WT_RENAMED | GIT_STATUS_WT_TYPECHANGE;

    summary->indexDirty = summary->indexDirty || ((statusFlags & indexFlags) != 0);
    summary->workdirDirty = summary->workdirDirty || ((statusFlags & workdirFlags) != 0);
    summary->conflicted = summary->conflicted || ((statusFlags & GIT_STATUS_CONFLICTED) != 0);
    return 0;
}

RepositoryStatus GetRepositoryStatus(git_repository *repo)
{
    RepositoryStatus summary;
    git_status_options options = GIT_STATUS_OPTIONS_INIT;
    options.show = GIT_STATUS_SHOW_INDEX_AND_WORKDIR;
    options.flags = GIT_STATUS_OPT_INCLUDE_UNTRACKED | GIT_STATUS_OPT_RENAMES_HEAD_TO_INDEX |
        GIT_STATUS_OPT_RENAMES_INDEX_TO_WORKDIR;
    CheckGit(git_status_foreach_ext(repo, &options, AccumulateStatus, &summary), "Unable to inspect repository status");
    return summary;
}

bool HasRepositoryChanges(git_repository *repo)
{
    RepositoryStatus status = GetRepositoryStatus(repo);
    return status.indexDirty || status.workdirDirty || status.conflicted;
}

bool HasRepairableIndexOnlyChanges(git_repository *repo)
{
    RepositoryStatus status = GetRepositoryStatus(repo);
    return status.indexDirty && !status.workdirDirty && !status.conflicted;
}

void ResetWorktreeTo(git_repository *repo, git_object *target, const std::string &message)
{
    git_checkout_options checkoutOpts = GIT_CHECKOUT_OPTIONS_INIT;
    checkoutOpts.checkout_strategy = GIT_CHECKOUT_FORCE | GIT_CHECKOUT_RECREATE_MISSING;
    CheckGit(git_reset(repo, target, GIT_RESET_HARD, &checkoutOpts), message);
}

void ResetWorktreeToHead(git_repository *repo)
{
    git_object *head = nullptr;
    CheckGit(git_revparse_single(&head, repo, "HEAD"), "Unable to resolve HEAD for worktree repair");
    try {
        ResetWorktreeTo(repo, head, "Unable to repair extension worktree");
    } catch (...) {
        git_object_free(head);
        throw;
    }
    git_object_free(head);
}

void FastForwardTo(git_repository *repo, const std::string &branch)
{
    if (HasRepositoryChanges(repo)) {
        throw std::runtime_error("Repository has local changes; update is refused to avoid overwriting files.");
    }

    std::string upstreamName = "refs/remotes/origin/" + branch;
    git_reference *upstreamRef = nullptr;
    CheckGit(git_reference_lookup(&upstreamRef, repo, upstreamName.c_str()), "Unable to resolve upstream branch");

    git_annotated_commit *theirHead = nullptr;
    int rc = git_annotated_commit_from_ref(&theirHead, repo, upstreamRef);
    git_reference_free(upstreamRef);
    CheckGit(rc, "Unable to inspect upstream branch");

    git_merge_analysis_t analysis = GIT_MERGE_ANALYSIS_NONE;
    git_merge_preference_t preference = GIT_MERGE_PREFERENCE_NONE;
    const git_annotated_commit *heads[1] = { theirHead };
    rc = git_merge_analysis(&analysis, &preference, repo, heads, 1);
    if (rc < 0) {
        git_annotated_commit_free(theirHead);
        CheckGit(rc, "Unable to analyze upstream merge");
    }

    if (analysis & GIT_MERGE_ANALYSIS_UP_TO_DATE) {
        git_annotated_commit_free(theirHead);
        return;
    }

    if (!(analysis & GIT_MERGE_ANALYSIS_FASTFORWARD) && !(analysis & GIT_MERGE_ANALYSIS_UNBORN)) {
        git_annotated_commit_free(theirHead);
        throw std::runtime_error("Upstream contains non-fast-forward changes; merge is not supported for extensions.");
    }

    const git_oid *targetOid = git_annotated_commit_id(theirHead);
    git_object *target = nullptr;
    rc = git_object_lookup(&target, repo, targetOid, GIT_OBJECT_COMMIT);
    if (rc < 0) {
        git_annotated_commit_free(theirHead);
        CheckGit(rc, "Unable to look up upstream commit");
    }

    std::string headRefName = "refs/heads/" + branch;
    git_reference *localRef = nullptr;
    if (git_reference_lookup(&localRef, repo, headRefName.c_str()) == 0) {
        git_reference *updatedRef = nullptr;
        rc = git_reference_set_target(&updatedRef, localRef, targetOid, "Fast-forward extension update");
        git_reference_free(localRef);
        if (updatedRef != nullptr) {
            git_reference_free(updatedRef);
        }
    } else {
        git_reference *createdRef = nullptr;
        rc = git_reference_create(&createdRef, repo, headRefName.c_str(), targetOid, 0,
            "Create local branch from origin");
        if (createdRef != nullptr) {
            git_reference_free(createdRef);
        }
    }
    if (rc < 0) {
        git_object_free(target);
        git_annotated_commit_free(theirHead);
        CheckGit(rc, "Unable to update local branch");
    }

    CheckGit(git_repository_set_head(repo, headRefName.c_str()), "Unable to set HEAD to updated branch");
    try {
        ResetWorktreeTo(repo, target, "Unable to reset worktree to updated branch");
    } catch (...) {
        git_object_free(target);
        git_annotated_commit_free(theirHead);
        throw;
    }

    git_object_free(target);
    git_annotated_commit_free(theirHead);
}

GitUpdateLikeResult BuildVersionResult(git_repository *repo, const std::string &path)
{
    GitUpdateLikeResult result;
    result.extensionPath = path;
    result.remoteUrl = RemoteUrl(repo);
    result.currentBranchName = CurrentBranch(repo);
    result.currentCommitHash = CurrentCommit(repo);
    result.shortCommitHash = ShortOid(result.currentCommitHash);
    result.isUpToDate = IsHeadUpToDateWithUpstream(repo, result.currentBranchName);
    return result;
}

void ReadCommitTreeIntoIndex(git_repository *repo, git_commit *commit)
{
    git_tree *tree = nullptr;
    CheckGit(git_commit_tree(&tree, commit), "Unable to read installed commit tree");

    git_index *index = nullptr;
    int rc = git_repository_index(&index, repo);
    if (rc < 0) {
        git_tree_free(tree);
        CheckGit(rc, "Unable to open repository index");
    }

    rc = git_index_read_tree(index, tree);
    if (rc == 0) {
        rc = git_index_write(index);
    }

    git_index_free(index);
    git_tree_free(tree);
    CheckGit(rc, "Unable to rebuild repository index");
}

void SetHeadAndIndexToCommit(git_repository *repo, const GitTask &task)
{
    git_oid oid;
    CheckGit(git_oid_fromstr(&oid, task.commit.c_str()), "Invalid installed commit");

    git_commit *commit = nullptr;
    CheckGit(git_commit_lookup(&commit, repo, &oid), "Unable to resolve installed commit");

    const std::string branch = NormalizeBranchReference(task.branch);
    int rc = 0;
    if (!branch.empty()) {
        const std::string headRefName = "refs/heads/" + branch;
        git_reference *branchRef = nullptr;
        rc = git_reference_create(&branchRef, repo, headRefName.c_str(), &oid, 1,
            "Rebuild extension Git metadata");
        if (branchRef != nullptr) {
            const std::string upstream = "origin/" + branch;
            git_branch_set_upstream(branchRef, upstream.c_str());
            git_reference_free(branchRef);
        }
        if (rc == 0) {
            rc = git_repository_set_head(repo, headRefName.c_str());
        }
    } else {
        rc = git_repository_set_head_detached(repo, &oid);
    }

    if (rc == 0) {
        ReadCommitTreeIntoIndex(repo, commit);
    }

    git_commit_free(commit);
    CheckGit(rc, "Unable to set HEAD to installed commit");
}

void ExecuteClone(GitTask &task)
{
    EnsureGitInitialized();
    ApplyCertLocation(task);

    git_clone_options cloneOpts = GIT_CLONE_OPTIONS_INIT;
    cloneOpts.checkout_opts.checkout_strategy = GIT_CHECKOUT_SAFE;
    ApplyCommonFetchOptions(cloneOpts.fetch_opts, task);
    if (!task.branch.empty()) {
        cloneOpts.checkout_branch = task.branch.c_str();
    }

    git_repository *repo = nullptr;
    int rc = git_clone(&repo, task.url.c_str(), task.path.c_str(), &cloneOpts);
    if (repo != nullptr) {
        git_repository_free(repo);
    }
    CheckGit(rc, "Unable to clone repository");
    task.stringResult = task.path;
}

void ExecuteRehydrate(GitTask &task)
{
    EnsureGitInitialized();
    ApplyCertLocation(task);

    if (task.url.empty()) {
        throw std::runtime_error("Repository URL is required");
    }
    if (task.path.empty()) {
        throw std::runtime_error("Repository path is required");
    }
    if (task.commit.empty()) {
        throw std::runtime_error("Installed commit is required");
    }

    git_repository *repo = nullptr;
    CheckGit(git_repository_init(&repo, task.path.c_str(), 0), "Unable to initialize repository metadata");
    try {
        EnsureOriginRemote(repo, task.url);
        EnsureAllOriginBranchesRefspec(repo);
        FetchOrigin(repo, task, false);
        SetHeadAndIndexToCommit(repo, task);
        task.updateResult = BuildVersionResult(repo, task.path);
    } catch (...) {
        git_repository_free(repo);
        throw;
    }

    git_repository_free(repo);
}

void ExecuteUpdate(GitTask &task)
{
    EnsureGitInitialized();
    ApplyCertLocation(task);

    git_repository *repo = nullptr;
    CheckGit(git_repository_open(&repo, task.path.c_str()), "Directory is not a Git repository");
    if (!HasRemote(repo)) {
        task.updateResult = BuildVersionResult(repo, task.path);
        task.updateResult.isUpToDate = true;
        git_repository_free(repo);
        return;
    }

    std::string branch = CurrentBranch(repo);
    bool wasUpToDate = true;
    if (!branch.empty()) {
        FetchOrigin(repo, task, false);
        wasUpToDate = IsHeadUpToDateWithUpstream(repo, branch);
        if (!wasUpToDate) {
            FastForwardTo(repo, branch);
        } else if (HasRepairableIndexOnlyChanges(repo)) {
            ResetWorktreeToHead(repo);
            wasUpToDate = false;
        }
    }

    task.updateResult = BuildVersionResult(repo, task.path);
    task.updateResult.isUpToDate = wasUpToDate;
    git_repository_free(repo);
}

void ExecuteVersion(GitTask &task)
{
    EnsureGitInitialized();
    ApplyCertLocation(task);

    git_repository *repo = nullptr;
    CheckGit(git_repository_open(&repo, task.path.c_str()), "Directory is not a Git repository");
    if (HasRemote(repo)) {
        FetchOrigin(repo, task, false);
    }
    task.updateResult = BuildVersionResult(repo, task.path);
    git_repository_free(repo);
}

GitBranchInfo BuildBranchInfo(git_repository *repo, git_reference *ref, git_branch_t type)
{
    GitBranchInfo info;
    const char *shorthand = git_reference_shorthand(ref);
    info.name = shorthand == nullptr ? "" : shorthand;
    if (type == GIT_BRANCH_REMOTE && info.name.rfind("origin/HEAD", 0) == 0) {
        info.name = "";
        return info;
    }

    const git_oid *oid = git_reference_target(ref);
    if (oid == nullptr) {
        git_object *peeled = nullptr;
        if (git_reference_peel(&peeled, ref, GIT_OBJECT_COMMIT) == 0 && peeled != nullptr) {
            oid = git_object_id(peeled);
            info.commit = OidToString(oid);
            git_object_free(peeled);
        }
    } else {
        info.commit = OidToString(oid);
    }

    if (type == GIT_BRANCH_LOCAL) {
        int isHead = git_branch_is_head(ref);
        info.current = isHead == 1;
    }
    info.label = info.commit.empty() ? "" : ShortOid(info.commit);
    return info;
}

void ExecuteBranches(GitTask &task)
{
    EnsureGitInitialized();
    ApplyCertLocation(task);

    git_repository *repo = nullptr;
    CheckGit(git_repository_open(&repo, task.path.c_str()), "Directory is not a Git repository");

    git_branch_iterator *iter = nullptr;
    CheckGit(git_branch_iterator_new(&iter, repo, static_cast<git_branch_t>(GIT_BRANCH_LOCAL | GIT_BRANCH_REMOTE)),
        "Unable to list branches");

    git_reference *ref = nullptr;
    git_branch_t type = GIT_BRANCH_LOCAL;
    while (git_branch_next(&ref, &type, iter) == 0) {
        GitBranchInfo info = BuildBranchInfo(repo, ref, type);
        if (!info.name.empty()) {
            task.branchesResult.push_back(info);
        }
        git_reference_free(ref);
        ref = nullptr;
    }

    git_branch_iterator_free(iter);
    git_repository_free(repo);
}

void ExecuteSwitchBranch(GitTask &task)
{
    EnsureGitInitialized();

    git_repository *repo = nullptr;
    CheckGit(git_repository_open(&repo, task.path.c_str()), "Directory is not a Git repository");

    std::string branch = task.branch;
    std::string targetRefName;
    if (branch.rfind("origin/", 0) == 0) {
        std::string localBranch = branch.substr(std::strlen("origin/"));
        std::string remoteRefName = "refs/remotes/" + branch;
        targetRefName = "refs/heads/" + localBranch;

        git_reference *localRef = nullptr;
        if (git_reference_lookup(&localRef, repo, targetRefName.c_str()) == 0) {
            git_reference_free(localRef);
        } else {
            git_reference *remoteRef = nullptr;
            CheckGit(git_reference_lookup(&remoteRef, repo, remoteRefName.c_str()), "Remote branch does not exist");
            const git_oid *remoteOid = git_reference_target(remoteRef);
            if (remoteOid == nullptr) {
                git_reference_free(remoteRef);
                throw std::runtime_error("Remote branch does not point to a commit");
            }
            git_commit *commit = nullptr;
            int rc = git_commit_lookup(&commit, repo, remoteOid);
            git_reference_free(remoteRef);
            CheckGit(rc, "Unable to read remote branch commit");

            git_reference *createdRef = nullptr;
            rc = git_branch_create(&createdRef, repo, localBranch.c_str(), commit, 0);
            git_commit_free(commit);
            if (createdRef != nullptr) {
                git_reference_free(createdRef);
            }
            CheckGit(rc, "Unable to create local branch from remote");
        }
    } else {
        targetRefName = "refs/heads/" + branch;
        git_reference *localRef = nullptr;
        int rc = git_reference_lookup(&localRef, repo, targetRefName.c_str());
        if (localRef != nullptr) {
            git_reference_free(localRef);
        }
        CheckGit(rc, "Branch does not exist locally");
    }

    CheckGit(git_repository_set_head(repo, targetRefName.c_str()), "Unable to switch HEAD");
    git_checkout_options checkoutOpts = GIT_CHECKOUT_OPTIONS_INIT;
    checkoutOpts.checkout_strategy = GIT_CHECKOUT_SAFE;
    int rc = git_checkout_head(repo, &checkoutOpts);
    git_repository_free(repo);
    CheckGit(rc, "Unable to checkout branch");
}

bool GetStringProperty(napi_env env, napi_value object, const char *name, std::string &out)
{
    bool hasProperty = false;
    napi_has_named_property(env, object, name, &hasProperty);
    if (!hasProperty) {
        return false;
    }

    napi_value value = nullptr;
    napi_get_named_property(env, object, name, &value);
    napi_valuetype type;
    napi_typeof(env, value, &type);
    if (type != napi_string) {
        return false;
    }

    size_t length = 0;
    napi_get_value_string_utf8(env, value, nullptr, 0, &length);
    std::vector<char> buffer(length + 1, '\0');
    napi_get_value_string_utf8(env, value, buffer.data(), buffer.size(), &length);
    out.assign(buffer.data(), length);
    return true;
}

bool GetBoolProperty(napi_env env, napi_value object, const char *name, bool &out)
{
    bool hasProperty = false;
    napi_has_named_property(env, object, name, &hasProperty);
    if (!hasProperty) {
        return false;
    }

    napi_value value = nullptr;
    napi_get_named_property(env, object, name, &value);
    napi_valuetype type;
    napi_typeof(env, value, &type);
    if (type != napi_boolean) {
        return false;
    }

    napi_get_value_bool(env, value, &out);
    return true;
}

bool GetIntProperty(napi_env env, napi_value object, const char *name, int &out)
{
    bool hasProperty = false;
    napi_has_named_property(env, object, name, &hasProperty);
    if (!hasProperty) {
        return false;
    }

    napi_value value = nullptr;
    napi_get_named_property(env, object, name, &value);
    napi_valuetype type;
    napi_typeof(env, value, &type);
    if (type != napi_number) {
        return false;
    }

    double number = 0;
    napi_get_value_double(env, value, &number);
    out = static_cast<int>(number);
    return true;
}

std::string GetStringArg(napi_env env, napi_value value)
{
    size_t length = 0;
    napi_get_value_string_utf8(env, value, nullptr, 0, &length);
    std::vector<char> buffer(length + 1, '\0');
    napi_get_value_string_utf8(env, value, buffer.data(), buffer.size(), &length);
    return std::string(buffer.data(), length);
}

napi_value CreateString(napi_env env, const std::string &value)
{
    napi_value result = nullptr;
    napi_create_string_utf8(env, value.c_str(), value.size(), &result);
    return result;
}

void SetString(napi_env env, napi_value object, const char *name, const std::string &value)
{
    napi_set_named_property(env, object, name, CreateString(env, value));
}

void SetBool(napi_env env, napi_value object, const char *name, bool value)
{
    napi_value boolValue = nullptr;
    napi_get_boolean(env, value, &boolValue);
    napi_set_named_property(env, object, name, boolValue);
}

napi_value CreateUpdateObject(napi_env env, const GitUpdateLikeResult &result)
{
    napi_value object = nullptr;
    napi_create_object(env, &object);
    SetString(env, object, "shortCommitHash", result.shortCommitHash);
    SetString(env, object, "currentCommitHash", result.currentCommitHash);
    SetString(env, object, "currentBranchName", result.currentBranchName);
    SetString(env, object, "extensionPath", result.extensionPath);
    SetBool(env, object, "isUpToDate", result.isUpToDate);
    SetString(env, object, "remoteUrl", result.remoteUrl);
    return object;
}

napi_value CreateBranchesArray(napi_env env, const std::vector<GitBranchInfo> &branches)
{
    napi_value array = nullptr;
    napi_create_array_with_length(env, branches.size(), &array);

    for (size_t i = 0; i < branches.size(); ++i) {
        napi_value object = nullptr;
        napi_create_object(env, &object);
        SetString(env, object, "name", branches[i].name);
        SetString(env, object, "commit", branches[i].commit);
        SetBool(env, object, "current", branches[i].current);
        SetString(env, object, "label", branches[i].label);
        napi_set_element(env, array, i, object);
    }

    return array;
}

void ExecuteGitTask(napi_env, void *data)
{
    GitTask *task = static_cast<GitTask *>(data);
    try {
        switch (task->kind) {
            case GitTaskKind::Clone:
                ExecuteClone(*task);
                break;
            case GitTaskKind::Rehydrate:
                ExecuteRehydrate(*task);
                break;
            case GitTaskKind::Update:
                ExecuteUpdate(*task);
                break;
            case GitTaskKind::Version:
                ExecuteVersion(*task);
                break;
            case GitTaskKind::Branches:
                ExecuteBranches(*task);
                break;
            case GitTaskKind::SwitchBranch:
                ExecuteSwitchBranch(*task);
                break;
        }
        task->ok = true;
    } catch (const std::exception &err) {
        task->ok = false;
        task->error = err.what();
    }
}

void CompleteGitTask(napi_env env, napi_status, void *data)
{
    std::unique_ptr<GitTask> task(static_cast<GitTask *>(data));
    if (!task->ok) {
        napi_value error = CreateString(env, task->error.empty() ? "Git operation failed" : task->error);
        napi_reject_deferred(env, task->deferred, error);
        napi_delete_async_work(env, task->work);
        return;
    }

    napi_value result = nullptr;
    switch (task->kind) {
        case GitTaskKind::Clone:
            result = CreateString(env, task->stringResult);
            break;
        case GitTaskKind::Rehydrate:
        case GitTaskKind::Update:
        case GitTaskKind::Version:
            result = CreateUpdateObject(env, task->updateResult);
            break;
        case GitTaskKind::Branches:
            result = CreateBranchesArray(env, task->branchesResult);
            break;
        case GitTaskKind::SwitchBranch:
            napi_get_undefined(env, &result);
            break;
    }

    napi_resolve_deferred(env, task->deferred, result);
    napi_delete_async_work(env, task->work);
}

napi_value QueueGitTask(napi_env env, std::unique_ptr<GitTask> task, const char *resourceName)
{
    napi_value promise = nullptr;
    napi_create_promise(env, &task->deferred, &promise);

    napi_value name = CreateString(env, resourceName);
    napi_create_async_work(env, nullptr, name, ExecuteGitTask, CompleteGitTask, task.get(), &task->work);
    napi_queue_async_work(env, task->work);
    task.release();
    return promise;
}

void ReadOptions(napi_env env, napi_value value, GitTask &task)
{
    if (value == nullptr) {
        return;
    }
    napi_valuetype type;
    napi_typeof(env, value, &type);
    if (type != napi_object) {
        return;
    }
    GetStringProperty(env, value, "branch", task.branch);
    GetStringProperty(env, value, "caBundlePath", task.caBundlePath);
    GetIntProperty(env, value, "depth", task.depth);
    GetBoolProperty(env, value, "unshallow", task.unshallow);
    GetBoolProperty(env, value, "allowInsecureCertificate", task.allowInsecureCertificate);
}

napi_value Clone(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value args[3] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    auto task = std::make_unique<GitTask>();
    task->env = env;
    task->kind = GitTaskKind::Clone;
    task->url = argc > 0 ? GetStringArg(env, args[0]) : "";
    task->path = argc > 1 ? GetStringArg(env, args[1]) : "";
    if (argc > 2) {
        ReadOptions(env, args[2], *task);
    }
    if (task->depth <= 0) {
        task->depth = 1;
    }
    return QueueGitTask(env, std::move(task), "tavernGitClone");
}

napi_value Rehydrate(napi_env env, napi_callback_info info)
{
    size_t argc = 5;
    napi_value args[5] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    auto task = std::make_unique<GitTask>();
    task->env = env;
    task->kind = GitTaskKind::Rehydrate;
    task->url = argc > 0 ? GetStringArg(env, args[0]) : "";
    task->path = argc > 1 ? GetStringArg(env, args[1]) : "";
    task->branch = argc > 2 ? GetStringArg(env, args[2]) : "";
    task->commit = argc > 3 ? GetStringArg(env, args[3]) : "";
    if (argc > 4) {
        ReadOptions(env, args[4], *task);
    }
    return QueueGitTask(env, std::move(task), "tavernGitRehydrate");
}

napi_value Update(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    auto task = std::make_unique<GitTask>();
    task->env = env;
    task->kind = GitTaskKind::Update;
    task->path = argc > 0 ? GetStringArg(env, args[0]) : "";
    if (argc > 1) {
        ReadOptions(env, args[1], *task);
    }
    return QueueGitTask(env, std::move(task), "tavernGitUpdate");
}

napi_value Version(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    auto task = std::make_unique<GitTask>();
    task->env = env;
    task->kind = GitTaskKind::Version;
    task->path = argc > 0 ? GetStringArg(env, args[0]) : "";
    if (argc > 1) {
        ReadOptions(env, args[1], *task);
    }
    return QueueGitTask(env, std::move(task), "tavernGitVersion");
}

napi_value Branches(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    auto task = std::make_unique<GitTask>();
    task->env = env;
    task->kind = GitTaskKind::Branches;
    task->path = argc > 0 ? GetStringArg(env, args[0]) : "";
    if (argc > 1) {
        ReadOptions(env, args[1], *task);
    }
    return QueueGitTask(env, std::move(task), "tavernGitBranches");
}

napi_value SwitchBranch(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    auto task = std::make_unique<GitTask>();
    task->env = env;
    task->kind = GitTaskKind::SwitchBranch;
    task->path = argc > 0 ? GetStringArg(env, args[0]) : "";
    task->branch = argc > 1 ? GetStringArg(env, args[1]) : "";
    return QueueGitTask(env, std::move(task), "tavernGitSwitchBranch");
}

napi_value GetNativeVersion(napi_env env, napi_callback_info)
{
    EnsureGitInitialized();
    int major = 0;
    int minor = 0;
    int rev = 0;
    git_libgit2_version(&major, &minor, &rev);
    std::ostringstream out;
    out << "libgit2 " << major << "." << minor << "." << rev;
    return CreateString(env, out.str());
}

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        { "getNativeVersion", nullptr, GetNativeVersion, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "clone", nullptr, Clone, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "rehydrate", nullptr, Rehydrate, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "update", nullptr, Update, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "version", nullptr, Version, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "branches", nullptr, Branches, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "switchBranch", nullptr, SwitchBranch, nullptr, nullptr, nullptr, napi_default, nullptr },
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

static napi_module tavernGitModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "tavern_git",
    .nm_priv = ((void*)0),
    .reserved = { 0 },
};

extern "C" __attribute__((constructor)) void RegisterTavernGitModule(void)
{
    napi_module_register(&tavernGitModule);
}

}
