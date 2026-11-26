// GeneralsX @feature Cursor 25/11/2026 First-launch macOS game-data folder picker.
// Resolves Zero Hour / Generals asset roots, persists the choice under
// ~/Library/Application Support/GeneralsX/, and exports the environment
// variables the engine already consults (CNC_GENERALS_ZH_PATH and friends).

#pragma once

#if defined(__APPLE__)

#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <sys/stat.h>
#include <unistd.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>

namespace Platform {

inline bool MacFileReadable(const char *path)
{
	return path && path[0] != '\0' && access(path, R_OK) == 0;
}

inline bool MacDirHasFile(const char *dir, const char *name)
{
	if (!dir || !dir[0] || !name) {
		return false;
	}
	char path[4096];
	snprintf(path, sizeof(path), "%s/%s", dir, name);
	return MacFileReadable(path);
}

inline bool MacIsZeroHourDataDir(const char *dir)
{
	return MacDirHasFile(dir, "INIZH.big")
		|| MacDirHasFile(dir, "inizh.big")
		|| MacDirHasFile(dir, "INIZH.BIG");
}

inline bool MacIsGeneralsDataDir(const char *dir)
{
	return MacDirHasFile(dir, "INI.big")
		|| MacDirHasFile(dir, "ini.big")
		|| MacDirHasFile(dir, "INI.BIG");
}

inline std::string MacHomeDir()
{
	const char *home = getenv("HOME");
	if (home && home[0] != '\0') {
		return home;
	}
	return std::string();
}

inline std::string MacSupportDir()
{
	const std::string home = MacHomeDir();
	if (home.empty()) {
		return std::string();
	}
	return home + "/Library/Application Support/GeneralsX";
}

inline bool MacEnsureDir(const std::string &dir)
{
	if (dir.empty()) {
		return false;
	}
	std::string current;
	for (size_t i = 0; i < dir.size(); ++i) {
		current.push_back(dir[i]);
		if (dir[i] == '/' || i + 1 == dir.size()) {
			if (current.size() <= 1) {
				continue;
			}
			if (mkdir(current.c_str(), 0755) != 0 && errno != EEXIST) {
				return false;
			}
		}
	}
	return true;
}

inline std::string MacTrim(std::string value)
{
	while (!value.empty() && (value.back() == '\n' || value.back() == '\r' || value.back() == ' ')) {
		value.pop_back();
	}
	size_t start = 0;
	while (start < value.size() && (value[start] == ' ' || value[start] == '\t')) {
		++start;
	}
	if (!value.empty() && value.back() == '/') {
		value.pop_back();
	}
	return value.substr(start);
}

inline bool MacNonInteractive()
{
	const char *ci = getenv("CI");
	const char *gha = getenv("GITHUB_ACTIONS");
	const char *skip = getenv("GX_NONINTERACTIVE");
	return (ci && ci[0] != '\0' && strcmp(ci, "0") != 0)
		|| (gha && gha[0] != '\0')
		|| (skip && skip[0] != '\0' && strcmp(skip, "0") != 0);
}

inline bool MacChooseFolder(const char *prompt, std::string &outPath)
{
	outPath.clear();
	if (MacNonInteractive() || !prompt) {
		return false;
	}
	char command[1024];
	snprintf(command, sizeof(command),
		"osascript -e 'POSIX path of (choose folder with prompt \"%s\")'",
		prompt);
	FILE *pipe = popen(command, "r");
	if (!pipe) {
		return false;
	}
	char buffer[4096];
	std::string collected;
	while (fgets(buffer, sizeof(buffer), pipe) != nullptr) {
		collected += buffer;
	}
	const int status = pclose(pipe);
	if (status != 0) {
		return false;
	}
	outPath = MacTrim(collected);
	return !outPath.empty();
}

inline std::string MacPathsFile()
{
	const std::string dir = MacSupportDir();
	if (dir.empty()) {
		return std::string();
	}
	return dir + "/data-paths.txt";
}

inline void MacReadSavedPaths(std::string &zhPath, std::string &generalsPath)
{
	const std::string filePath = MacPathsFile();
	if (filePath.empty()) {
		return;
	}
	FILE *file = fopen(filePath.c_str(), "r");
	if (!file) {
		return;
	}
	char line[4096];
	while (fgets(line, sizeof(line), file) != nullptr) {
		std::string text = MacTrim(line);
		if (text.compare(0, 3, "zh=") == 0) {
			zhPath = text.substr(3);
		} else if (text.compare(0, 9, "generals=") == 0) {
			generalsPath = text.substr(9);
		}
	}
	fclose(file);
}

inline void MacWriteSavedPaths(const std::string &zhPath, const std::string &generalsPath)
{
	const std::string dir = MacSupportDir();
	const std::string filePath = MacPathsFile();
	if (dir.empty() || filePath.empty() || !MacEnsureDir(dir)) {
		return;
	}
	FILE *file = fopen(filePath.c_str(), "w");
	if (!file) {
		return;
	}
	if (!zhPath.empty()) {
		fprintf(file, "zh=%s\n", zhPath.c_str());
	}
	if (!generalsPath.empty()) {
		fprintf(file, "generals=%s\n", generalsPath.c_str());
	}
	fclose(file);

	// Mirror InstallPath into registry.ini so the engine's existing registry
	// lookup (GetStringFromRegistry "InstallPath") finds the same folders.
	const std::string registryPath = dir + "/registry.ini";
	std::string existing;
	FILE *existingFile = fopen(registryPath.c_str(), "r");
	if (existingFile) {
		char buffer[1024];
		while (fgets(buffer, sizeof(buffer), existingFile) != nullptr) {
			existing += buffer;
		}
		fclose(existingFile);
	}
	FILE *registry = fopen(registryPath.c_str(), "a");
	if (!registry) {
		return;
	}
	const char *zhSection = "[hkey_current_user\\software\\electronic arts\\ea games\\command and conquer generals zero hour]";
	const char *generalsSection = "[hkey_current_user\\software\\electronic arts\\ea games\\generals]";
	if (!zhPath.empty() && existing.find(zhSection) == std::string::npos) {
		fprintf(registry, "\n%s\ninstallpath=%s\n", zhSection, zhPath.c_str());
	}
	if (!generalsPath.empty() && existing.find(generalsSection) == std::string::npos) {
		fprintf(registry, "\n%s\ninstallpath=%s\n", generalsSection, generalsPath.c_str());
	}
	fclose(registry);
}

inline std::string MacExecutableDir()
{
	char raw[1024] = {0};
	uint32_t size = sizeof(raw);
	if (_NSGetExecutablePath(raw, &size) != 0) {
		return std::string();
	}
	char real[1024] = {0};
	if (realpath(raw, real) == nullptr) {
		return std::string();
	}
	char *slash = strrchr(real, '/');
	if (!slash) {
		return std::string();
	}
	*slash = '\0';
	return real;
}

inline bool MacBundleLibrary(const char *libraryName, char *out, size_t outSize)
{
	if (!libraryName || !out || outSize == 0) {
		return false;
	}
	const std::string exeDir = MacExecutableDir();
	if (exeDir.empty()) {
		return false;
	}
	snprintf(out, outSize, "%s/../Frameworks/%s", exeDir.c_str(), libraryName);
	return MacFileReadable(out);
}

inline void MacCopyBundleFileTo(const char *relativeSource, const std::string &destPath)
{
	const std::string exeDir = MacExecutableDir();
	if (exeDir.empty() || destPath.empty()) {
		return;
	}
	char source[1024];
	snprintf(source, sizeof(source), "%s/%s", exeDir.c_str(), relativeSource);
	if (!MacFileReadable(source)) {
		return;
	}
	FILE *in = fopen(source, "rb");
	FILE *out = fopen(destPath.c_str(), "wb");
	if (!in || !out) {
		if (in) {
			fclose(in);
		}
		if (out) {
			fclose(out);
		}
		return;
	}
	char buffer[8192];
	size_t readCount = 0;
	while ((readCount = fread(buffer, 1, sizeof(buffer), in)) > 0) {
		if (fwrite(buffer, 1, readCount, out) != readCount) {
			break;
		}
	}
	fclose(in);
	fclose(out);
}

inline void MacExportAssetEnv(bool zeroHour, const std::string &zhPath, const std::string &generalsPath)
{
	if (zeroHour && !zhPath.empty()) {
		setenv("CNC_GENERALS_ZH_PATH", zhPath.c_str(), 1);
		setenv("CNC_ZH_INSTALLPATH", zhPath.c_str(), 1);
	}
	if (!generalsPath.empty()) {
		setenv("CNC_GENERALS_PATH", generalsPath.c_str(), 1);
		setenv("CNC_GENERALS_INSTALLPATH", generalsPath.c_str(), 1);
	} else if (!zeroHour && !zhPath.empty()) {
		setenv("CNC_GENERALS_PATH", zhPath.c_str(), 1);
		setenv("CNC_GENERALS_INSTALLPATH", zhPath.c_str(), 1);
	}
}

inline void MacConfigureBundleRuntime()
{
	setenv("DXVK_WSI_DRIVER", "SDL3", 0);
	// GeneralsX @bugfix Cursor 26/11/2026 D3DRS_PATCHSEGMENTS is logged once per draw as a warning.
	// Keep pipeline compile errors. A launch can still override this.
	if (getenv("DXVK_LOG_LEVEL") == nullptr) {
		setenv("DXVK_LOG_LEVEL", "error", 0);
	}

	const std::string exeDir = MacExecutableDir();
	if (exeDir.empty()) {
		return;
	}

	char icd[1024];
	snprintf(icd, sizeof(icd), "%s/../Frameworks/MoltenVK_icd.json", exeDir.c_str());
	if (!MacFileReadable(icd)) {
		snprintf(icd, sizeof(icd), "%s/../Resources/MoltenVK_icd.json", exeDir.c_str());
	}
	if (MacFileReadable(icd)) {
		setenv("VK_ICD_FILENAMES", icd, 1);
		setenv("VK_DRIVER_FILES", icd, 1);
		fprintf(stderr, "INFO: VK_ICD_FILENAMES=%s\n", icd);
	} else {
		fprintf(stderr, "WARNING: MoltenVK ICD manifest was not found next to the app\n");
	}

	char dxvkConf[1024];
	snprintf(dxvkConf, sizeof(dxvkConf), "%s/../Resources/dxvk.conf", exeDir.c_str());
	if (MacFileReadable(dxvkConf)) {
		setenv("DXVK_CONFIG_FILE", dxvkConf, 0);
	}

	char fontsConf[1024];
	snprintf(fontsConf, sizeof(fontsConf), "%s/../Resources/fontconfig/fonts.conf", exeDir.c_str());
	if (MacFileReadable(fontsConf)) {
		setenv("FONTCONFIG_FILE", fontsConf, 0);
		char fontsDir[1024];
		snprintf(fontsDir, sizeof(fontsDir), "%s/../Resources/fontconfig", exeDir.c_str());
		setenv("FONTCONFIG_PATH", fontsDir, 0);
	}

	char bundleFonts[1024];
	snprintf(bundleFonts, sizeof(bundleFonts), "%s/../Resources/fonts", exeDir.c_str());
	if (MacFileReadable(bundleFonts) || access(bundleFonts, F_OK) == 0) {
		setenv("GX_BUNDLE_FONTS", bundleFonts, 0);
	}

	char patch[1024];
	if (MacBundleLibrary("libsage_patch.dylib", patch, sizeof(patch))) {
		dlopen(patch, RTLD_NOW | RTLD_GLOBAL);
	}
}

// GeneralsX @bugfix Cursor 25/11/2026 Load the same dylibs DX8Wrapper::Init dlopens,
// before game data is required, so CI can prove the bundle is complete.
inline bool MacProbeDxvkLibraries()
{
	MacConfigureBundleRuntime();
	const char *names[] = {
		"libdxvk_d3d8.dylib",
		"libdxvk_d3d9.dylib",
		"libMoltenVK.dylib",
		"libvulkan.dylib"
	};
	bool ok = true;
	for (const char *name : names) {
		char path[1024];
		if (!MacBundleLibrary(name, path, sizeof(path))) {
			fprintf(stderr, "GX_PROBE_DXVK: missing %s in Contents/Frameworks\n", name);
			ok = false;
			continue;
		}
		void *handle = dlopen(path, RTLD_NOW | RTLD_LOCAL);
		if (!handle) {
			fprintf(stderr, "GX_PROBE_DXVK: dlopen %s failed: %s\n", path, dlerror());
			ok = false;
			continue;
		}
		fprintf(stderr, "GX_PROBE_DXVK: loaded %s\n", path);
		if (strcmp(name, "libdxvk_d3d8.dylib") == 0) {
			void *symbol = dlsym(handle, "Direct3DCreate8");
			if (!symbol) {
				symbol = dlsym(handle, "_Direct3DCreate8");
			}
			if (!symbol) {
				fprintf(stderr, "GX_PROBE_DXVK: Direct3DCreate8 missing: %s\n", dlerror());
				ok = false;
			} else {
				fprintf(stderr, "GX_PROBE_DXVK: Direct3DCreate8=%p\n", symbol);
			}
		}
	}
	const char *icd = getenv("VK_ICD_FILENAMES");
	if (!icd || !MacFileReadable(icd)) {
		fprintf(stderr, "GX_PROBE_DXVK: MoltenVK ICD manifest is not readable\n");
		ok = false;
	} else {
		fprintf(stderr, "GX_PROBE_DXVK: ICD %s\n", icd);
	}
	fflush(stderr);
	return ok;
}

inline std::string MacWindowTitle(const char *baseTitle)
{
#ifdef GENERALSX_APP_VERSION
	std::string title = baseTitle ? baseTitle : "";
	const char *version = GENERALSX_APP_VERSION;
	if (version && version[0] != '\0' && title.find(version) == std::string::npos) {
		if (!title.empty()) {
			title += " ";
		}
		title += version;
	}
	return title;
#else
	return baseTitle ? baseTitle : "";
#endif
}

// Returns false when the required game data folder is still missing.
// Callers should exit before SDL/Vulkan startup so a headless machine
// does not crash inside the GPU stack.
inline bool MacEnsureGameData(bool zeroHour)
{
	std::string zhPath;
	std::string generalsPath;
	const char *envZh = getenv("CNC_GENERALS_ZH_PATH");
	const char *envGen = getenv("CNC_GENERALS_PATH");
	if (envZh && envZh[0] != '\0') {
		zhPath = MacTrim(envZh);
	}
	if (envGen && envGen[0] != '\0') {
		generalsPath = MacTrim(envGen);
	}

	std::string savedZh;
	std::string savedGen;
	MacReadSavedPaths(savedZh, savedGen);
	if (zhPath.empty()) {
		zhPath = savedZh;
	}
	if (generalsPath.empty()) {
		generalsPath = savedGen;
	}

	const std::string home = MacHomeDir();
	if (!home.empty()) {
		const char *zhCandidates[] = {
			"/GeneralsX/GeneralsZH",
			"/GeneralsX/GeneralsMD",
			"/GeneralsX/data/GeneralsZH",
			"/Documents/Command and Conquer Generals Zero Hour Data",
			"/Documents/Command & Conquer Generals Zero Hour Data"
		};
		if (zeroHour && (zhPath.empty() || !MacIsZeroHourDataDir(zhPath.c_str()))) {
			zhPath.clear();
			for (const char *suffix : zhCandidates) {
				const std::string candidate = home + suffix;
				if (MacIsZeroHourDataDir(candidate.c_str())) {
					zhPath = candidate;
					break;
				}
			}
		}
		if (generalsPath.empty() || !MacIsGeneralsDataDir(generalsPath.c_str())) {
			const std::string homeGenerals = home + "/GeneralsX/Generals";
			if (MacIsGeneralsDataDir(homeGenerals.c_str())) {
				generalsPath = homeGenerals;
			} else if (!zhPath.empty() && MacIsGeneralsDataDir((zhPath + "/ZH_Generals").c_str())) {
				generalsPath = zhPath + "/ZH_Generals";
			} else if (!MacIsGeneralsDataDir(generalsPath.c_str())) {
				generalsPath.clear();
			}
		}
	}

	const bool haveRequired = zeroHour
		? MacIsZeroHourDataDir(zhPath.c_str())
		: MacIsGeneralsDataDir(generalsPath.empty() ? zhPath.c_str() : generalsPath.c_str());

	if (!haveRequired) {
		std::string picked;
		const char *prompt = zeroHour
			? "Select the Zero Hour Data folder (the folder that contains INIZH.big)"
			: "Select the Generals Data folder (the folder that contains INI.big)";
		if (MacChooseFolder(prompt, picked)) {
			if (zeroHour && MacIsZeroHourDataDir(picked.c_str())) {
				zhPath = picked;
			} else if (!zeroHour && MacIsGeneralsDataDir(picked.c_str())) {
				generalsPath = picked;
				zhPath = picked;
			} else {
				fprintf(stderr, "GeneralsX: selected folder does not contain the expected game archives.\n");
			}
		}
	}

	if (zeroHour && MacIsZeroHourDataDir(zhPath.c_str()) && generalsPath.empty() && !MacNonInteractive()) {
		std::string pickedGenerals;
		if (MacChooseFolder("Select the Generals Data folder (optional, Cancel to skip)", pickedGenerals)
			&& MacIsGeneralsDataDir(pickedGenerals.c_str())) {
			generalsPath = pickedGenerals;
		}
	}

	const bool ready = zeroHour
		? MacIsZeroHourDataDir(zhPath.c_str())
		: MacIsGeneralsDataDir(generalsPath.empty() ? zhPath.c_str() : generalsPath.c_str());
	if (!ready) {
		fprintf(stderr, "=================================================\n");
#ifdef GENERALSX_APP_VERSION
		fprintf(stderr, " GeneralsX %s\n", GENERALSX_APP_VERSION);
#endif
		if (zeroHour) {
			fprintf(stderr, " Zero Hour data was not found.\n");
			fprintf(stderr, " Choose the folder that contains INIZH.big.\n");
		} else {
			fprintf(stderr, " Generals data was not found.\n");
			fprintf(stderr, " Choose the folder that contains INI.big.\n");
		}
		fprintf(stderr, " The choice is saved in ~/Library/Application Support/GeneralsX/.\n");
		fprintf(stderr, "=================================================\n");
		fflush(stderr);
		return false;
	}

	MacExportAssetEnv(zeroHour, zhPath, generalsPath);
	MacWriteSavedPaths(zeroHour ? zhPath : std::string(), generalsPath.empty() && !zeroHour ? zhPath : generalsPath);

	if (zeroHour && !zhPath.empty()) {
		MacCopyBundleFileTo("../Resources/generalsx.big", zhPath + "/generalsx.big");
		fprintf(stderr, "INFO: Zero Hour data: %s\n", zhPath.c_str());
	}
	if (!generalsPath.empty()) {
		fprintf(stderr, "INFO: Generals data: %s\n", generalsPath.c_str());
	}
	fflush(stderr);
	return true;
}

} // namespace Platform

#endif // __APPLE__
