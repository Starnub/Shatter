// SHATTER: per-pass GPU timing via nvrhi timer queries. Results arrive a few frames late and are accumulated while recording.
#pragma once

#include <map>
#include <string>
#include <vector>

#include <nvrhi/nvrhi.h>

namespace shatter
{
    class GpuProfiler
    {
    public:
        struct Stat
        {
            double sumMs = 0.0;
            double maxMs = 0.0;
            uint64_t count = 0;
            double AvgMs() const { return count ? sumMs / double(count) : 0.0; }
        };

        void Init(nvrhi::IDevice* device) { m_device = device; }

        // Call once per frame before recording any Begin/End. Resolves the frame that last used this ring slot.
        void BeginFrame();

        // Passes must not overlap. Begin/End are no-ops until Init() has been called.
        void Begin(nvrhi::ICommandList* commandList, const char* name);
        void End(nvrhi::ICommandList* commandList);

        void SetRecording(bool recording) { m_recording = recording; }
        const std::map<std::string, Stat>& Stats() const { return m_stats; }

    private:
        struct Entry { std::string name; nvrhi::TimerQueryHandle query; };
        static constexpr int kRing = 4;

        nvrhi::IDevice* m_device = nullptr;
        std::vector<Entry> m_frames[kRing];
        std::vector<nvrhi::TimerQueryHandle> m_pool;
        int m_slot = 0;
        bool m_open = false;
        bool m_recording = false;
        std::map<std::string, Stat> m_stats;
    };
}
