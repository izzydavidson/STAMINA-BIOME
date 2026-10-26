import { BarChart, Bar, XAxis, YAxis, CartesianGrid, Tooltip, ResponsiveContainer, LineChart, Line } from 'recharts';
import { FileText, CheckCircle, Clock, AlertTriangle, Download, Upload } from 'lucide-react';
import { useState } from 'react';

const projectData = [
  { name: 'Mon', samples: 12 },
  { name: 'Tue', samples: 19 },
  { name: 'Wed', samples: 15 },
  { name: 'Thu', samples: 22 },
  { name: 'Fri', samples: 18 },
  { name: 'Sat', samples: 8 },
  { name: 'Sun', samples: 5 },
];

const runTimeData = [
  { range: '0-30min', count: 8 },
  { range: '30-60min', count: 15 },
  { range: '1-2hr', count: 22 },
  { range: '2-4hr', count: 18 },
  { range: '4-8hr', count: 12 },
  { range: '8hr+', count: 6 },
];

export function DashboardPage() {
  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-gray-900">Dashboard</h1>
        <p className="text-gray-600">Overview of sequencing analysis projects</p>
      </div>

      {/* Return to Wizard Button */}
      <div>
        <button className="bg-blue-600 hover:bg-blue-700 text-white px-6 py-2 rounded-md transition-colors">
          Return to Wizard
        </button>
      </div>

      {/* BAM to FASTQ Preprocessing Tool */}
      <BamToFastqConverter />

      {/* Stats Grid */}
      <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-4">
        <StatCard
          icon={FileText}
          label="Total Projects"
          value="47"
          color="bg-blue-50 text-blue-600"
        />
        <StatCard
          icon={CheckCircle}
          label="Completed"
          value="32"
          color="bg-green-50 text-green-600"
        />
        <StatCard
          icon={Clock}
          label="In Progress"
          value="12"
          color="bg-amber-50 text-amber-600"
        />
        <StatCard
          icon={AlertTriangle}
          label="Failed"
          value="3"
          color="bg-red-50 text-red-600"
        />
      </div>

      {/* Charts */}
      <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
        <div className="bg-white rounded-lg shadow-sm border border-gray-200 p-6">
          <h3 className="text-gray-900 mb-4">Samples Analyzed (Last 7 Days)</h3>
          <ResponsiveContainer width="100%" height={250}>
            <BarChart data={projectData}>
              <CartesianGrid strokeDasharray="3 3" />
              <XAxis dataKey="name" />
              <YAxis />
              <Tooltip />
              <Bar dataKey="samples" fill="#2563eb" name="Samples" />
            </BarChart>
          </ResponsiveContainer>
        </div>

        <div className="bg-white rounded-lg shadow-sm border border-gray-200 p-6">
          <h3 className="text-gray-900 mb-4">Pipeline Run Time Distribution</h3>
          <ResponsiveContainer width="100%" height={250}>
            <BarChart data={runTimeData}>
              <CartesianGrid strokeDasharray="3 3" />
              <XAxis dataKey="range" />
              <YAxis />
              <Tooltip />
              <Bar dataKey="count" fill="#7c3aed" name="Runs" />
            </BarChart>
          </ResponsiveContainer>
        </div>
      </div>

      {/* Recent Projects */}
      <div className="bg-white rounded-lg shadow-sm border border-gray-200 p-6">
        <h3 className="text-gray-900 mb-4">Recent Projects</h3>
        <div className="overflow-x-auto">
          <table className="w-full">
            <thead className="bg-gray-50 border-b border-gray-200">
              <tr>
                <th className="px-4 py-3 text-left text-gray-700">Project Name</th>
                <th className="px-4 py-3 text-left text-gray-700">Type</th>
                <th className="px-4 py-3 text-left text-gray-700">Samples</th>
                <th className="px-4 py-3 text-left text-gray-700">Status</th>
                <th className="px-4 py-3 text-left text-gray-700">Date</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-gray-200">
              <ProjectRow
                name="BRCA1_variant_study"
                type="Short Read"
                samples="24"
                status="Completed"
                date="2026-01-04"
              />
              <ProjectRow
                name="metagenome_analysis"
                type="Long Read"
                samples="16"
                status="In Progress"
                date="2026-01-05"
              />
              <ProjectRow
                name="transcriptome_seq"
                type="Short Read"
                samples="32"
                status="Completed"
                date="2026-01-03"
              />
              <ProjectRow
                name="structural_variants"
                type="Long Read"
                samples="8"
                status="In Progress"
                date="2026-01-05"
              />
              <ProjectRow
                name="cancer_panel_seq"
                type="Short Read"
                samples="48"
                status="Completed"
                date="2026-01-02"
              />
            </tbody>
          </table>
        </div>
      </div>
    </div>
  );
}

function StatCard({ icon: Icon, label, value, color }: any) {
  return (
    <div className="bg-white rounded-lg shadow-sm border border-gray-200 p-6">
      <div className="flex items-center justify-between">
        <div>
          <p className="text-gray-600 text-sm mb-1">{label}</p>
          <p className="text-gray-900 text-2xl">{value}</p>
        </div>
        <div className={`p-3 rounded-lg ${color}`}>
          <Icon className="w-6 h-6" />
        </div>
      </div>
    </div>
  );
}

function ProjectRow({ name, type, samples, status, date }: any) {
  const statusColors = {
    'Completed': 'bg-green-100 text-green-700',
    'In Progress': 'bg-amber-100 text-amber-700',
    'Failed': 'bg-red-100 text-red-700',
  };

  return (
    <tr className="hover:bg-gray-50">
      <td className="px-4 py-3 text-gray-900">{name}</td>
      <td className="px-4 py-3 text-gray-600">{type}</td>
      <td className="px-4 py-3 text-gray-600">{samples}</td>
      <td className="px-4 py-3">
        <span className={`px-2 py-1 rounded text-sm ${statusColors[status as keyof typeof statusColors]}`}>
          {status}
        </span>
      </td>
      <td className="px-4 py-3 text-gray-600">{date}</td>
    </tr>
  );
}

function BamToFastqConverter() {
  const [bamFile, setBamFile] = useState<File | null>(null);
  const [converting, setConverting] = useState(false);
  const [convertedFile, setConvertedFile] = useState<string | null>(null);

  const handleFileChange = (event: React.ChangeEvent<HTMLInputElement>) => {
    const file = event.target.files?.[0];
    if (file) {
      setBamFile(file);
      setConvertedFile(null);
    }
  };

  const handleConvert = () => {
    if (bamFile) {
      setConverting(true);
      // Simulate conversion process
      setTimeout(() => {
        setConvertedFile(bamFile.name.replace('.bam', '.fastq'));
        setConverting(false);
      }, 2000);
    }
  };

  const handleDownload = () => {
    if (convertedFile) {
      // Create mock FASTQ content
      const fastqContent = `@SEQ_ID_1
GATTTGGGGTTCAAAGCAGTATCGATCAAATAGTAAATCCATTTGTTCAACTCACAGTTT
+
!''*((((***+))%%%++)(%%%%).1***-+*''))**55CCF>>>>>>CCCCCCC65
@SEQ_ID_2
GCTGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCG
+
CCCFFFFFGHHHHJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJ
@SEQ_ID_3
ATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCG
+
@@@DDDDDHHHHHIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIII`;

      // Create a blob and trigger download
      const blob = new Blob([fastqContent], { type: 'text/plain' });
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url;
      a.download = convertedFile;
      document.body.appendChild(a);
      a.click();
      document.body.removeChild(a);
      URL.revokeObjectURL(url);
    }
  };

  return (
    <div className="bg-white rounded-lg shadow-sm border border-gray-200 p-6">
      <div className="flex items-center gap-2 mb-4">
        <Upload className="w-5 h-5 text-gray-700" />
        <h3 className="text-gray-900">Preprocessing: BAM to FASTQ Converter</h3>
      </div>
      
      <p className="text-gray-600 text-sm mb-4">
        Convert BAM alignment files to FASTQ format for downstream sequencing analysis
      </p>

      <div className="space-y-4">
        <div>
          <label className="block text-gray-700 mb-2 text-sm">Select BAM File</label>
          <input
            type="file"
            accept=".bam"
            onChange={handleFileChange}
            className="block w-full text-sm text-gray-500 
              file:mr-4 file:py-2 file:px-4 
              file:rounded-md file:border file:border-gray-300
              file:text-sm file:bg-gray-50
              file:text-gray-700 hover:file:bg-gray-100
              cursor-pointer"
          />
        </div>

        {bamFile && (
          <div className="flex items-center gap-4">
            <button
              onClick={handleConvert}
              disabled={converting}
              className="bg-blue-600 hover:bg-blue-700 disabled:bg-gray-400 text-white px-4 py-2 rounded-md flex items-center gap-2 transition-colors"
            >
              {converting ? (
                <>
                  <div className="w-4 h-4 border-2 border-white border-t-transparent rounded-full animate-spin" />
                  Converting...
                </>
              ) : (
                <>
                  <FileText className="w-4 h-4" />
                  Convert to FASTQ
                </>
              )}
            </button>

            {convertedFile && (
              <button
                onClick={handleDownload}
                className="bg-green-600 hover:bg-green-700 text-white px-4 py-2 rounded-md flex items-center gap-2 transition-colors"
              >
                <Download className="w-4 h-4" />
                Download {convertedFile}
              </button>
            )}
          </div>
        )}

        {convertedFile && (
          <div className="p-3 bg-green-50 border border-green-200 rounded-md">
            <p className="text-sm text-green-900">
              ✓ Conversion complete: <span className="font-mono">{convertedFile}</span>
            </p>
          </div>
        )}
      </div>
    </div>
  );
}