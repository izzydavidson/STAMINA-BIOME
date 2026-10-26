import { BarChart, Bar, XAxis, YAxis, CartesianGrid, Tooltip, ResponsiveContainer, LineChart, Line } from 'recharts';
import { CheckCircle, AlertCircle, TrendingUp } from 'lucide-react';
import { ReadType } from '../App';

interface ResultsPanelProps {
  readType: ReadType;
  showResults: boolean;
  analysisRunning: boolean;
}

const shortReadQualityData = [
  { position: '1-10', avgQuality: 35 },
  { position: '11-20', avgQuality: 36 },
  { position: '21-30', avgQuality: 37 },
  { position: '31-40', avgQuality: 38 },
  { position: '41-50', avgQuality: 37 },
  { position: '51-60', avgQuality: 36 },
  { position: '61-70', avgQuality: 34 },
  { position: '71-80', avgQuality: 32 },
  { position: '81-90', avgQuality: 30 },
  { position: '91-100', avgQuality: 28 },
];

const longReadLengthData = [
  { range: '0-5kb', count: 1200 },
  { range: '5-10kb', count: 3400 },
  { range: '10-15kb', count: 5600 },
  { range: '15-20kb', count: 4200 },
  { range: '20-25kb', count: 2800 },
  { range: '25-30kb', count: 1600 },
  { range: '30kb+', count: 800 },
];

const shortReadStats = {
  totalReads: '125,432',
  passedQC: '118,654 (94.6%)',
  avgLength: '148 bp',
  avgQuality: '35.2',
  gcContent: '42.3%',
};

const longReadStats = {
  totalReads: '19,623',
  passedQC: '18,234 (92.9%)',
  avgLength: '12,456 bp',
  n50: '15,234 bp',
  gcContent: '43.1%',
};

export function ResultsPanel({ readType, showResults, analysisRunning }: ResultsPanelProps) {
  if (!showResults && !analysisRunning) {
    return (
      <div className="bg-white rounded-lg shadow-sm border border-gray-200 p-12">
        <div className="text-center text-gray-500">
          <TrendingUp className="w-16 h-16 mx-auto mb-4 text-gray-300" />
          <h3 className="text-gray-700 mb-2">No Results Yet</h3>
          <p>Configure parameters and click "Run Analysis" to see results</p>
        </div>
      </div>
    );
  }

  if (analysisRunning) {
    return (
      <div className="bg-white rounded-lg shadow-sm border border-gray-200 p-12">
        <div className="text-center">
          <div className="w-16 h-16 border-4 border-blue-600 border-t-transparent rounded-full animate-spin mx-auto mb-4" />
          <h3 className="text-gray-700 mb-2">Running Analysis...</h3>
          <p className="text-gray-500">Processing {readType === 'short' ? 'short' : 'long'} read sequencing data</p>
        </div>
      </div>
    );
  }

  const stats = readType === 'short' ? shortReadStats : longReadStats;

  return (
    <div className="space-y-6">
      {/* Status Banner */}
      <div className="bg-green-50 border border-green-200 rounded-lg p-4 flex items-center gap-3">
        <CheckCircle className="w-6 h-6 text-green-600" />
        <div>
          <h3 className="text-green-900">Analysis Complete</h3>
          <p className="text-sm text-green-700">
            {readType === 'short' ? 'Short read' : 'Long read'} sequencing analysis finished successfully
          </p>
        </div>
      </div>

      {/* Summary Statistics */}
      <div className="bg-white rounded-lg shadow-sm border border-gray-200 p-6">
        <h3 className="text-gray-900 mb-4">Summary Statistics</h3>
        <div className="grid grid-cols-2 md:grid-cols-3 gap-4">
          <StatCard label="Total Reads" value={stats.totalReads} />
          <StatCard label="Passed QC" value={stats.passedQC} />
          <StatCard label="Average Length" value={stats.avgLength} />
          {readType === 'short' ? (
            <StatCard label="Average Quality" value={stats.avgQuality} />
          ) : (
            <StatCard label="N50 Length" value={stats.n50} />
          )}
          <StatCard label="GC Content" value={stats.gcContent} />
          <StatCard 
            label="Status" 
            value="PASS" 
            valueColor="text-green-600"
          />
        </div>
      </div>

      {/* Quality Visualization */}
      <div className="bg-white rounded-lg shadow-sm border border-gray-200 p-6">
        <h3 className="text-gray-900 mb-4">
          {readType === 'short' ? 'Per-Base Quality Distribution' : 'Read Length Distribution'}
        </h3>
        <ResponsiveContainer width="100%" height={300}>
          {readType === 'short' ? (
            <LineChart data={shortReadQualityData}>
              <CartesianGrid strokeDasharray="3 3" />
              <XAxis dataKey="position" />
              <YAxis domain={[0, 40]} />
              <Tooltip />
              <Line type="monotone" dataKey="avgQuality" stroke="#2563eb" strokeWidth={2} name="Avg Quality" />
            </LineChart>
          ) : (
            <BarChart data={longReadLengthData}>
              <CartesianGrid strokeDasharray="3 3" />
              <XAxis dataKey="range" />
              <YAxis />
              <Tooltip />
              <Bar dataKey="count" fill="#2563eb" name="Read Count" />
            </BarChart>
          )}
        </ResponsiveContainer>
      </div>

      {/* Warnings/Notes */}
      <div className="bg-amber-50 border border-amber-200 rounded-lg p-4 flex items-start gap-3">
        <AlertCircle className="w-5 h-5 text-amber-600 mt-0.5" />
        <div>
          <h4 className="text-amber-900">Analysis Notes</h4>
          <ul className="text-sm text-amber-700 mt-1 space-y-1">
            {readType === 'short' ? (
              <>
                <li>• Quality scores decline slightly towards read ends (typical for Illumina)</li>
                <li>• 5.4% of reads filtered due to quality threshold</li>
                <li>• Adapter contamination: 2.3%</li>
              </>
            ) : (
              <>
                <li>• Read length distribution shows expected long-read profile</li>
                <li>• 7.1% of reads filtered (below minimum length threshold)</li>
                <li>• Error correction improved consensus accuracy</li>
              </>
            )}
          </ul>
        </div>
      </div>
    </div>
  );
}

function StatCard({ label, value, valueColor = 'text-gray-900' }: { label: string; value: string; valueColor?: string }) {
  return (
    <div className="p-4 bg-gray-50 rounded-md border border-gray-200">
      <p className="text-sm text-gray-600 mb-1">{label}</p>
      <p className={`${valueColor}`}>{value}</p>
    </div>
  );
}
