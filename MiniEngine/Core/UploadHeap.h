#pragma once
#include <queue>

struct RingBuffer
{
	struct AllocInfo
	{
		size_t offset;
		size_t size;
		uint64_t frameValue;
	};

	~RingBuffer();

	// Allocates the backing buffer for the ring buffer
	void init(size_t size);
	// Sub-allocates in the ring buffer
	size_t subAllocate(size_t size, size_t align);
	// Return the free memory
	size_t getFreeSize();
	//
	ID3D12Resource * getResourceHandle() { return m_uploadBuffer; }

public:
	// Free memory by overiding sub-allocation from the processed frames
	// Note: can wait on the GPU to process frames
	void freeMemory_waitGPU(size_t sizeAlign);
	// Push back the alloc info to the dequeue
	void recordAllocInfo(uint64_t frameIdx, size_t size, size_t align);
	//
	void freeMemoryUntilFrame(uint64_t frameIdx);

	byte * m_data;
	size_t m_curOffset;
	size_t m_endOffset;
	size_t m_size;
	ID3D12Heap * m_uploadHeap;
	ID3D12Resource * m_uploadBuffer;
	std::deque<AllocInfo> m_metaData;
};

class UploadHeap
{
public:
	UploadHeap(size_t bufferSize);
	~UploadHeap();
	byte * allocate(size_t size, size_t align);
	byte * allocateInitialized(size_t size, size_t align, byte* data);
private:
	RingBuffer m_uploadBuffer;
};

extern void TestUploadHeap();
