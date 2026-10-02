#include "GpuProfiler.h"

#include <algorithm>

namespace shatter
{
    void GpuProfiler::BeginFrame()
    {
        if (!m_device)
            return;

        m_slot = (m_slot + 1) % kRing;

        // This slot was last written kRing frames ago; its queries should have completed.
        for (Entry& e : m_frames[m_slot])
        {
            // queries that never resolve (e.g. command list not executed) are simply dropped
            if (m_recording && m_device->pollTimerQuery(e.query))
            {
                const double ms = double(m_device->getTimerQueryTime(e.query)) * 1000.0;
                Stat& s = m_stats[e.name];
                s.sumMs += ms;
                s.maxMs = std::max(s.maxMs, ms);
                s.count++;
            }
            m_pool.push_back(std::move(e.query));
        }
        m_frames[m_slot].clear();
    }

    void GpuProfiler::Begin(nvrhi::ICommandList* commandList, const char* name)
    {
        if (!m_device || m_open)
            return;

        nvrhi::TimerQueryHandle query;
        if (!m_pool.empty())
        {
            query = std::move(m_pool.back());
            m_pool.pop_back();
        }
        else
            query = m_device->createTimerQuery();

        commandList->beginTimerQuery(query);
        m_frames[m_slot].push_back({ name, query });
        m_open = true;
    }

    void GpuProfiler::End(nvrhi::ICommandList* commandList)
    {
        if (!m_device || !m_open)
            return;

        commandList->endTimerQuery(m_frames[m_slot].back().query);
        m_open = false;
    }
}
