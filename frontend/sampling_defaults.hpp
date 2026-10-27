#pragma once

#include "common.h"
#include "json.h"

namespace strata_frontend {

// Keep thinking selection aligned with oaicompat_chat_params_parse in server-common.cpp.
inline bool sampling_thinking(const common_json & body, bool enabled,
                              const std::map<std::string, std::string> & template_kwargs) {
    auto it = template_kwargs.find("enable_thinking");
    if (it != template_kwargs.end()) {
        if (it->second == "true") enabled = true;
        if (it->second == "false") enabled = false;
    }
    if (body.contains("chat_template_kwargs")) {
        const auto & kwargs = body.at("chat_template_kwargs");
        if (kwargs.contains("enable_thinking") && kwargs.at("enable_thinking").is_boolean()) {
            enabled = kwargs.at("enable_thinking").get<bool>();
        }
    }
    if (body.contains("reasoning_effort") && body.at("reasoning_effort").is_string()
        && body.at("reasoning_effort").get<std::string>() == "none") enabled = false;
    return enabled;
}

// Qwen's Best Practices. Unknown architectures retain llama.cpp's defaults.
// Server flags override the card field by field; request fields are filled only when absent.
inline common_json sampling_defaults(const std::string & arch, bool thinking,
                                     const common_params_sampling & s, bool presence_override) {
    if (arch != "qwen4exp" && arch != "qwen35moe") return common_json::object();
    const auto mask = s.user_sampling_config;
    return {
        {"temperature", mask & COMMON_PARAMS_SAMPLING_CONFIG_TEMP ? s.temp : thinking ? 1.0f : 0.7f},
        {"top_p", mask & COMMON_PARAMS_SAMPLING_CONFIG_TOP_P ? s.top_p : thinking ? 0.95f : 0.8f},
        {"top_k", mask & COMMON_PARAMS_SAMPLING_CONFIG_TOP_K ? s.top_k : 20},
        {"min_p", mask & COMMON_PARAMS_SAMPLING_CONFIG_MIN_P ? s.min_p : 0.0f},
        {"repeat_penalty", mask & COMMON_PARAMS_SAMPLING_CONFIG_PENALTY_REPEAT ? s.penalty_repeat : 1.0f},
        {"presence_penalty", presence_override ? s.penalty_present : thinking && arch == "qwen4exp" ? 0.0f : 1.5f},
    };
}

inline void fill_sampling_defaults(common_json & body, const common_json & defaults) {
    for (const auto & item : defaults.items()) {
        if (!body.contains(item.key()) || body.at(item.key()).is_null()) body[item.key()] = item.value();
    }
}

} // namespace strata_frontend
