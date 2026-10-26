import { useState } from 'react';
import { Play, FileText, Settings } from 'lucide-react';
import { ReadType } from '../App';

interface ParameterPanelProps {
  readType: ReadType;
  setReadType: (type: ReadType) => void;
  onRunAnalysis: () => void;
  analysisRunning: boolean;
}

export function ParameterPanel({ readType, setReadType, onRunAnalysis, analysisRunning }: ParameterPanelProps) {
  // Short read parameters
  const [shortReadQuality, setShortReadQuality] = useState(20);
  const [shortReadLength, setShortReadLength] = useState(50);
  const [trimAdapter, setTrimAdapter] = useState(true);
  const [deduplication, setDeduplication] = useState(false);

  // Long read parameters
  const [longReadQuality, setLongReadQuality] = useState(7);
  const [minReadLength, setMinReadLength] = useState(1000);
  const [maxReadLength, setMaxReadLength] = useState(50000);
  const [errorCorrection, setErrorCorrection] = useState(true);

  return (
    <div className="bg-white rounded-lg shadow-sm border border-gray-200 p-6">
      <div className="flex items-center gap-2 mb-6">
        <Settings className="w-5 h-5 text-gray-700" />
        <h2 className="text-gray-900">Analysis Parameters</h2>
      </div>

      {/* Read Type Selection */}
      <div className="mb-6">
        <label className="block text-gray-700 mb-2">Sequencing Technology</label>
        <div className="grid grid-cols-2 gap-2">
          <button
            onClick={() => setReadType('short')}
            className={`px-4 py-3 rounded-md border transition-all ${
              readType === 'short'
                ? 'bg-blue-50 border-blue-500 text-blue-700'
                : 'bg-white border-gray-300 text-gray-700 hover:bg-gray-50'
            }`}
          >
            Short Read
          </button>
          <button
            onClick={() => setReadType('long')}
            className={`px-4 py-3 rounded-md border transition-all ${
              readType === 'long'
                ? 'bg-blue-50 border-blue-500 text-blue-700'
                : 'bg-white border-gray-300 text-gray-700 hover:bg-gray-50'
            }`}
          >
            Long Read
          </button>
        </div>
        <p className="text-sm text-gray-500 mt-2">
          {readType === 'short' ? 'Illumina, Ion Torrent' : 'PacBio, Oxford Nanopore'}
        </p>
      </div>

      <div className="border-t border-gray-200 pt-6">
        {readType === 'short' ? (
          <ShortReadParameters
            quality={shortReadQuality}
            setQuality={setShortReadQuality}
            minLength={shortReadLength}
            setMinLength={setShortReadLength}
            trimAdapter={trimAdapter}
            setTrimAdapter={setTrimAdapter}
            deduplication={deduplication}
            setDeduplication={setDeduplication}
          />
        ) : (
          <LongReadParameters
            quality={longReadQuality}
            setQuality={setLongReadQuality}
            minLength={minReadLength}
            setMinLength={setMinReadLength}
            maxLength={maxReadLength}
            setMaxLength={setMaxReadLength}
            errorCorrection={errorCorrection}
            setErrorCorrection={setErrorCorrection}
          />
        )}
      </div>

      {/* Run Analysis Button */}
      <button
        onClick={onRunAnalysis}
        disabled={analysisRunning}
        className="w-full mt-6 bg-blue-600 hover:bg-blue-700 disabled:bg-gray-400 text-white px-4 py-3 rounded-md flex items-center justify-center gap-2 transition-colors"
      >
        {analysisRunning ? (
          <>
            <div className="w-5 h-5 border-2 border-white border-t-transparent rounded-full animate-spin" />
            Running Analysis...
          </>
        ) : (
          <>
            <Play className="w-5 h-5" />
            Run Analysis
          </>
        )}
      </button>

      {/* Input File Info */}
      <div className="mt-6 p-4 bg-gray-50 rounded-md border border-gray-200">
        <div className="flex items-center gap-2 mb-2">
          <FileText className="w-4 h-4 text-gray-600" />
          <span className="text-sm text-gray-700">Input Files</span>
        </div>
        <p className="text-sm text-gray-600">sample_reads.fastq</p>
        <p className="text-sm text-gray-500">125,432 reads</p>
      </div>
    </div>
  );
}

function ShortReadParameters({ quality, setQuality, minLength, setMinLength, trimAdapter, setTrimAdapter, deduplication, setDeduplication }: any) {
  return (
    <div className="space-y-5">
      <div>
        <label className="block text-gray-700 mb-2">
          Quality Score Threshold: <span className="text-blue-600">{quality}</span>
        </label>
        <input
          type="range"
          min="0"
          max="40"
          value={quality}
          onChange={(e) => setQuality(Number(e.target.value))}
          className="w-full"
        />
        <div className="flex justify-between text-xs text-gray-500 mt-1">
          <span>0 (Low)</span>
          <span>40 (High)</span>
        </div>
      </div>

      <div>
        <label className="block text-gray-700 mb-2">
          Minimum Read Length: <span className="text-blue-600">{minLength} bp</span>
        </label>
        <input
          type="range"
          min="20"
          max="300"
          value={minLength}
          onChange={(e) => setMinLength(Number(e.target.value))}
          className="w-full"
        />
        <div className="flex justify-between text-xs text-gray-500 mt-1">
          <span>20 bp</span>
          <span>300 bp</span>
        </div>
      </div>

      <div className="flex items-center gap-2">
        <input
          type="checkbox"
          id="trimAdapter"
          checked={trimAdapter}
          onChange={(e) => setTrimAdapter(e.target.checked)}
          className="w-4 h-4 text-blue-600 rounded"
        />
        <label htmlFor="trimAdapter" className="text-gray-700">
          Trim Adapter Sequences
        </label>
      </div>

      <div className="flex items-center gap-2">
        <input
          type="checkbox"
          id="deduplication"
          checked={deduplication}
          onChange={(e) => setDeduplication(e.target.checked)}
          className="w-4 h-4 text-blue-600 rounded"
        />
        <label htmlFor="deduplication" className="text-gray-700">
          Remove PCR Duplicates
        </label>
      </div>
    </div>
  );
}

function LongReadParameters({ quality, setQuality, minLength, setMinLength, maxLength, setMaxLength, errorCorrection, setErrorCorrection }: any) {
  return (
    <div className="space-y-5">
      <div>
        <label className="block text-gray-700 mb-2">
          Minimum Quality Score: <span className="text-blue-600">{quality}</span>
        </label>
        <input
          type="range"
          min="0"
          max="20"
          value={quality}
          onChange={(e) => setQuality(Number(e.target.value))}
          className="w-full"
        />
        <div className="flex justify-between text-xs text-gray-500 mt-1">
          <span>0 (Low)</span>
          <span>20 (High)</span>
        </div>
      </div>

      <div>
        <label className="block text-gray-700 mb-2">
          Minimum Read Length: <span className="text-blue-600">{minLength.toLocaleString()} bp</span>
        </label>
        <input
          type="range"
          min="500"
          max="10000"
          step="500"
          value={minLength}
          onChange={(e) => setMinLength(Number(e.target.value))}
          className="w-full"
        />
        <div className="flex justify-between text-xs text-gray-500 mt-1">
          <span>500 bp</span>
          <span>10 kb</span>
        </div>
      </div>

      <div>
        <label className="block text-gray-700 mb-2">
          Maximum Read Length: <span className="text-blue-600">{maxLength.toLocaleString()} bp</span>
        </label>
        <input
          type="range"
          min="10000"
          max="100000"
          step="5000"
          value={maxLength}
          onChange={(e) => setMaxLength(Number(e.target.value))}
          className="w-full"
        />
        <div className="flex justify-between text-xs text-gray-500 mt-1">
          <span>10 kb</span>
          <span>100 kb</span>
        </div>
      </div>

      <div className="flex items-center gap-2">
        <input
          type="checkbox"
          id="errorCorrection"
          checked={errorCorrection}
          onChange={(e) => setErrorCorrection(e.target.checked)}
          className="w-4 h-4 text-blue-600 rounded"
        />
        <label htmlFor="errorCorrection" className="text-gray-700">
          Apply Error Correction
        </label>
      </div>
    </div>
  );
}
