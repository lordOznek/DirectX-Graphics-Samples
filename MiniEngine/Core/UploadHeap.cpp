#include "pch.h"
#include "UploadHeap.h"
#include "GraphicsCore.h"
#include "CommandListManager.h"

UploadHeap::UploadHeap(size_t bufferSize)
{
	m_uploadBuffer.init(bufferSize);
}

UploadHeap::~UploadHeap()
{
}

byte* UploadHeap::allocate(size_t size, size_t align)
{
	size_t offset = m_uploadBuffer.subAllocate(size, align);
	return m_uploadBuffer.m_data + offset;
}

byte * UploadHeap::allocateInitialized(size_t size, size_t align, byte * data)
{
	byte * ptr = allocate(size, align);
	if (ptr != nullptr) 
	{
		memcpy_s(ptr, size, data, size);
	}
	return ptr;
}

RingBuffer::~RingBuffer()
{
	CD3DX12_RANGE writtenRange(0, 0);
	m_uploadBuffer->Unmap(0, &writtenRange);
	m_uploadBuffer->Release();
}

void RingBuffer::init(size_t size)
{
	HRESULT hr = Graphics::g_Device->CreateCommittedResource(
		&CD3DX12_HEAP_PROPERTIES(D3D12_HEAP_TYPE_UPLOAD),
		D3D12_HEAP_FLAG_NONE,
		&CD3DX12_RESOURCE_DESC::Buffer(size),
		D3D12_RESOURCE_STATE_GENERIC_READ, nullptr,
		IID_PPV_ARGS(&m_uploadBuffer));
	
	if (S_OK == hr) 
	{
		CD3DX12_RANGE readRange(0, 0);
		m_uploadBuffer->Map(0, &readRange, (void**)&m_data);
	}

	m_curOffset = m_endOffset = 0U;
}

size_t RingBuffer::subAllocate(size_t size, size_t align)
{
	uint64_t alignMask = align - 1;
	size_t sizeAligned = (size + alignMask) & ~alignMask;

	if (m_size < sizeAligned)
	{
		assert(!"3 2 1 BOOM!!!");
		return -1;
	}

	uint64_t fenceValue = Graphics::g_CommandManager.GetGraphicsQueue().GetNextFenceValue();
	if (sizeAligned < getFreeSize())
	{
		size_t offsetAligned = (m_curOffset + alignMask) & ~alignMask;
		m_curOffset = (m_curOffset + sizeAligned) % m_size;
		m_endOffset = (m_endOffset + sizeAligned) % m_size;
		recordAllocInfo(fenceValue, size, offsetAligned);
		return (offsetAligned % m_size);
	}
	else
	{
		freeMemory_waitGPU(sizeAligned);
		return subAllocate(size, align);
	}
}

size_t RingBuffer::getFreeSize()
{
	if (m_curOffset < m_endOffset) 
	{
		return m_endOffset - m_curOffset;
	}
	return m_size - m_curOffset + m_endOffset;
}

void RingBuffer::freeMemory_waitGPU(size_t sizeAlign)
{
	uint64_t lastCompleted = Graphics::g_CommandManager.GetGraphicsQueue().GetLastCompletedFenceValue();
	freeMemoryUntilFrame(lastCompleted);

	while (getFreeSize() < sizeAlign && m_metaData.size() > 0)
	{
		Graphics::g_CommandManager.GetGraphicsQueue().WaitForFence(m_metaData.front().frameValue);
		freeMemoryUntilFrame(m_metaData.front().frameValue);
	}

	if (m_metaData.size() > 0)
	{
		m_endOffset = m_metaData.front().offset;
	}
	else
	{
		m_curOffset = m_endOffset = 0U;
	}
}

void RingBuffer::recordAllocInfo(uint64_t frameIdx, size_t size, size_t offset)
{
	AllocInfo info{};
	info.offset = offset;
	info.size = size;
	info.frameValue = frameIdx;
	m_metaData.push_back(info);
}

void RingBuffer::freeMemoryUntilFrame(uint64_t frameIdx)
{
	while (m_metaData.size() > 0 && m_metaData.front().frameValue <= frameIdx)
	{
		m_metaData.pop_front();
	}
}

void TestUploadHeap()
{
	UploadHeap heap(1024 * 1024);

	size_t size = 512 * 1024;
	byte * data = new byte[size];
	memset(data, 0xab, size);
	heap.allocateInitialized(size, 64*1024, data);
}
